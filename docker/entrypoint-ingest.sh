#!/bin/bash
set -e

echo "=================================================="
echo "Code Ingestion Service"
echo "=================================================="

. /usr/local/lib/code-ingest/load-secret-files.sh
load_secret_files DEEPINFRA_API_KEY GITHUB_TOKEN QDRANT_API_KEY

# Required env vars — fail fast with a clear message.
missing=()
if [ -z "${DEEPINFRA_API_KEY:-}" ]; then
    missing+=("DEEPINFRA_API_KEY")
fi
if [ -z "${GITHUB_TOKEN:-}" ]; then
    missing+=("GITHUB_TOKEN")
fi
if [ "${#missing[@]}" -gt 0 ]; then
    echo "❌ Missing required environment variable(s): ${missing[*]}" >&2
    echo "   Set them in your .env file (docker compose) or in the Railway service variables, then redeploy." >&2
    exit 1
fi

# Wait for Qdrant to be ready
echo "⏳ Waiting for Qdrant..."
max_attempts=30
attempt=0

# Determine Qdrant URL (default to local Docker, or use cloud URL)
QDRANT_CHECK_URL="${QDRANT_URL:-http://qdrant:6333}"

while [ $attempt -lt $max_attempts ]; do
    # Try connection with API key if provided (for Qdrant Cloud)
    if [ -n "${QDRANT_API_KEY}" ]; then
        if curl -sf -H "api-key: ${QDRANT_API_KEY}" "${QDRANT_CHECK_URL}/" > /dev/null 2>&1; then
            echo "✅ Qdrant is ready"
            break
        fi
    else
        # No API key - try without auth (for local Docker Qdrant)
        if curl -sf "${QDRANT_CHECK_URL}/" > /dev/null 2>&1; then
            echo "✅ Qdrant is ready"
            break
        fi
    fi
    
    attempt=$((attempt + 1))
    echo "   Attempt $attempt/$max_attempts - waiting 2s..."
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo "❌ Qdrant did not become healthy in time"
    exit 1
fi

# Refresh existing clones, then clone whatever the config lists that is not on
# disk yet. The cloner skips repos that already exist, so running it every time
# is what picks up repos added to config/repositories.yaml on a persistent
# volume (Railway, the ss-ai PVC). Detect clones by */.git rather than `ls -A`:
# ext4 volumes contain lost+found.
shopt -s nullglob
existing_git_dirs=(/app/repos/*/.git)
shopt -u nullglob

if [ ${#existing_git_dirs[@]} -gt 0 ]; then
    echo "🔄 Refreshing ${#existing_git_dirs[@]} existing repositories (git pull)..."
    for git_dir in "${existing_git_dirs[@]}"; do
        repo_dir="${git_dir%/.git}"
        name=$(basename "$repo_dir")
        echo "   Refreshing $name..."
        (cd "$repo_dir" && git pull --ff-only) || true
    done
    echo "✅ Repositories refreshed"
fi

echo "📥 Cloning missing repositories..."
# A single failed clone (revoked access, timeout) must not block ingestion of
# everything else; the cloner already logs each failure.
if python -m modules.ingest.scripts.repo_cloner --min-priority "${PRIORITY:-high}"; then
    echo "✅ Repositories cloned"
else
    echo "⚠️  Some repositories failed to clone; continuing with what is on disk"
fi

# Update discovered config (Helm, languages, repo type)
echo "🔍 Running repository discovery..."
python -m modules.ingest.scripts.repo_discovery || true

# Run ingestion
echo "🚀 Starting ingestion pipeline..."
python -c "
from modules import IngestionPipeline
import sys
import os
import logging

# Configure logging so pipeline/file_processor/batch_processor INFO logs are visible
level_name = os.getenv('LOG_LEVEL', 'INFO').upper()
level = getattr(logging, level_name, logging.INFO)
logging.basicConfig(
    level=level,
    format='%(levelname)s: %(message)s',
    stream=sys.stdout,
)
# Reduce noise from third-party libs unless DEBUG
if level_name != 'DEBUG':
    logging.getLogger('httpx').setLevel(logging.WARNING)
    logging.getLogger('httpcore').setLevel(logging.WARNING)
    logging.getLogger('openai').setLevel(logging.WARNING)

try:
    pipeline = IngestionPipeline()
    priority = os.getenv('PRIORITY', 'high')
    print(f'📊 Running ingestion with priority: {priority}')
    stats = pipeline.ingest_repositories(min_priority=priority)
    
    if 'error' in stats:
        print(f'❌ Ingestion failed: {stats[\"error\"]}')
        sys.exit(1)
    
    print('✅ Ingestion complete!')
    total_chunks = stats.get('total_chunks')
    if total_chunks is None and 'chunks_by_collection' in stats:
        total_chunks = sum(stats['chunks_by_collection'].values())
    print(f'   Total chunks: {total_chunks or 0}')
    print(f'   Repositories: {stats.get(\"repositories_processed\", 0)}')
    
    # Write completion status
    with open('/app/status/ingestion_complete', 'w') as f:
        f.write('complete')
    
    sys.exit(0)
except Exception as e:
    print(f'❌ Ingestion failed with exception: {e}')
    import traceback
    traceback.print_exc()
    sys.exit(1)
"

# Update derived service_dependencies from YAML/Helm
echo "🔗 Deriving service dependencies..."
python -m modules.ingest.scripts.derive_dependencies || true

echo "=================================================="
echo "Ingestion service completed"
echo "=================================================="
