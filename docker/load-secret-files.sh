# Sourced by the container entrypoints.
#
# load_secret_files VAR...: for each VAR whose VAR_FILE is set, export VAR from
# that file. This lets credentials arrive as mounted files (Secrets Store CSI,
# Docker secrets) instead of Kubernetes Secrets injected as env. Plain env vars
# (docker compose, Railway) keep working unchanged.
load_secret_files() {
    local var file_var file
    for var in "$@"; do
        file_var="${var}_FILE"
        file="${!file_var:-}"
        [ -n "$file" ] || continue
        if [ -n "${!var:-}" ]; then
            echo "❌ Both $var and $file_var are set; set only one" >&2
            return 1
        fi
        if [ ! -r "$file" ]; then
            echo "❌ $file_var points at $file, which is missing or unreadable" >&2
            return 1
        fi
        # $(...) strips trailing newlines, which secret files often carry.
        export "$var=$(cat "$file")"
    done
}
