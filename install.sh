#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
TARGET_DIR="$HOME/.local/bin"
TARGET="$TARGET_DIR/papat"

/bin/mkdir -p "$TARGET_DIR"
/bin/cp "$SCRIPT_DIR/papat" "$TARGET"
/bin/chmod 755 "$TARGET"
print -r -- "インストールしました: $TARGET"
case ":$PATH:" in
  *":$TARGET_DIR:"*) print -r -- 'PATH は設定済みです。papat --help で確認できます。' ;;
  *)
    print -r -- '次の行を ~/.zshrc に追加して、新しいターミナルを開いてください:'
    print -r -- 'export PATH="$HOME/.local/bin:$PATH"'
    ;;
esac
