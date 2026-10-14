#!/bin/bash
set -e

echo "=================================================="
echo "Code Ingestion Service"
echo "=================================================="

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

# Clone or refresh repositories.
# Detect cloned repos by the presence of */.git rather than `ls -A`, because
# Railway volumes (ext4) contain a lost+found directory that would otherwise
# make the mount look non-empty and skip the initial clone.
shopt -s nullglob
existing_git_dirs=(/app/repos/*/.git)
shopt -u nullglob

if [ ${#existing_git_dirs[@]} -eq 0 ]; then
    echo "📥 Cloning repositories..."
    python -m modules.ingest.scripts.repo_cloner --min-priority "${PRIORITY:-high}"
    echo "✅ Repositories cloned"
else
    echo "🔄 Refreshing existing repositories (git pull)..."
    for git_dir in "${existing_git_dirs[@]}"; do
        repo_dir="${git_dir%/.git}"
        name=$(basename "$repo_dir")
        echo "   Refreshing $name..."
        (cd "$repo_dir" && git pull --ff-only) || true
    done
    echo "✅ Repositories refreshed"
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
