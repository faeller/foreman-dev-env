#!/bin/bash
# plugin management for foreman-dev-env

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ENV_DIR="$(dirname "$SCRIPT_DIR")"
PLUGINS_PATH="${PLUGINS_PATH:-$DEV_ENV_DIR/foreman-plugins}"
BUNDLER_DIR="$DEV_ENV_DIR/bundler.d"

cd "$DEV_ENV_DIR"

# load and export .env (override any stale shell vars)
if [ -f .env ]; then
    unset RAILS_ENV FOREMAN_DOCKERFILE FOREMAN_VERSION
    source .env
    export RAILS_ENV FOREMAN_DOCKERFILE FOREMAN_VERSION
fi

usage() {
    echo "usage: $0 <command> [args]"
    echo ""
    echo "commands:"
    echo "  status            show plugins dir and discovered plugins"
    echo "  sync              scan plugins dir and update bundler.d"
    echo "  install           sync + bundle install + restart (all in one)"
    echo "  add <path>        symlink plugin into plugins dir and install"
    echo "  rm <name>         remove plugin from bundler.d"
    echo "  restart           restart foreman services"
    echo ""
    echo "plugins dir: $PLUGINS_PATH"
}

show_status() {
    echo "plugins: $PLUGINS_PATH"

    if [ ! -d "$PLUGINS_PATH" ]; then
        echo "  (dir doesn't exist)"
        exit 0
    fi

    echo ""
    shopt -s nullglob
    local count=0
    for gemspec in "$PLUGINS_PATH"/*/*.gemspec "$PLUGINS_PATH"/*.gemspec; do
        [ -f "$gemspec" ] || continue
        local name=$(basename "$gemspec" .gemspec)
        local synced="x"
        [ -f "$BUNDLER_DIR/${name}.local.rb" ] && synced="✓"
        printf "  [%s] %s\n" "$synced" "$name"
        count=$((count + 1))
    done
    shopt -u nullglob

    [ $count -eq 0 ] && echo "  (no plugins found)"
    true
}

sync_plugins() {
    echo "scanning $PLUGINS_PATH..."

    if [ ! -d "$PLUGINS_PATH" ]; then
        mkdir -p "$PLUGINS_PATH"
        echo "created $PLUGINS_PATH"
    fi

    mkdir -p "$BUNDLER_DIR"
    rm -f "$BUNDLER_DIR"/*.local.rb 2>/dev/null || true

    local count=0
    shopt -s nullglob
    for gemspec in "$PLUGINS_PATH"/*/*.gemspec "$PLUGINS_PATH"/*.gemspec; do
        [ -f "$gemspec" ] || continue

        local plugin_dir=$(dirname "$gemspec")
        local plugin_name=$(basename "$plugin_dir")
        local gem_name
        gem_name=$(ruby -e "puts Gem::Specification.load('$gemspec').name" 2>/dev/null) || gem_name=$(basename "$gemspec" .gemspec)

        echo "  + $gem_name"
        echo "gem '$gem_name', path: '/home/foreman/plugins/external/$plugin_name'" > "$BUNDLER_DIR/${gem_name}.local.rb"
        count=$((count + 1))
    done
    shopt -u nullglob

    echo "synced $count plugin(s)"
    [ $count -gt 0 ] && echo "restart foreman to load"
}

restart_foreman() {
    echo "restarting foreman services..."
    env -u RAILS_ENV -u FOREMAN_DOCKERFILE docker compose restart foreman orchestrator worker
    echo "done"
}

install_plugins() {
    sync_plugins

    if ls "$BUNDLER_DIR"/*.local.rb 1>/dev/null 2>&1; then
        echo ""
        echo "installing plugin dependencies..."
        env -u RAILS_ENV -u FOREMAN_DOCKERFILE docker compose run --rm foreman bundle install
        echo ""
        restart_foreman
    else
        echo "no plugins to install"
    fi
}

add_plugin() {
    local path="$1"
    [ -z "$path" ] && { echo "usage: $0 add <path>"; exit 1; }
    [ ! -d "$path" ] && { echo "error: $path not a directory"; exit 1; }

    local gemspec=$(find "$path" -maxdepth 1 -name "*.gemspec" | head -1)
    [ -z "$gemspec" ] && { echo "error: no .gemspec in $path"; exit 1; }

    local plugin_name=$(basename "$path")
    local target="$PLUGINS_PATH/$plugin_name"

    mkdir -p "$PLUGINS_PATH"
    [ -e "$target" ] && { echo "error: $target exists"; exit 1; }

    ln -s "$(realpath "$path")" "$target"
    echo "linked $plugin_name"
    install_plugins
}

remove_plugin() {
    local name="$1"
    [ -z "$name" ] && { echo "usage: $0 rm <name>"; exit 1; }

    local rb="$BUNDLER_DIR/${name}.local.rb"
    [ -f "$rb" ] || { echo "error: $name not in bundler.d"; exit 1; }

    rm "$rb"
    echo "removed $name"
}

case "${1:-}" in
    status|st|ls|list|"") show_status ;;
    sync) sync_plugins ;;
    install|i) install_plugins ;;
    add) add_plugin "$2" ;;
    rm|remove) remove_plugin "$2" ;;
    restart|r) restart_foreman ;;
    -h|--help|help) usage ;;
    *) echo "unknown: $1"; usage; exit 1 ;;
esac
