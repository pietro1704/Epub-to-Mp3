#!/usr/bin/env bash
# Break the bloated default VS Code profile into lean, per-domain profiles.
# Idempotent: re-running only adds what's missing.
#
# Profiles created:
#   Flutter   — Dart/Flutter dev (riverpod + freezed flavoured)
#   iOS       — SwiftUI / Xcode bridge
#   Python    — Python + Pylance + debug
#   Web       — TS/React/Tailwind
#   Ruby      — Rails / Ruby LSP
#   LaTeX     — papers
#   Cpp       — C/C++ + CMake
#   Strudel   — live-coding music
#
# After install, prunes the DEFAULT profile down to a vim-first core:
#   vim, gitlens, claude-code, copilot-chat, icons, 1 theme, markdown, yaml, shell

set -u

code_bin=$(command -v code) || { echo "VS Code 'code' CLI not in PATH"; exit 1; }

# VS Code only persists new profile entries to storage.json when no
# instance owns the lock. If a window is open, --profile <NewName> will
# silently fail with "Profile 'X' not found". Bail out loudly.
if pgrep -fq "MacOS/Electron|Visual Studio Code"; then
  echo "ERROR: VS Code is running. Quit it completely (Cmd-Q) and re-run."
  exit 2
fi

install_in_profile() {
  local profile="$1"; shift
  for ext in "$@"; do
    echo "  [$profile] + $ext"
    "$code_bin" --profile "$profile" --install-extension "$ext" --force >/dev/null 2>&1 \
      || echo "    (skip: $ext)"
  done
}

uninstall_default() {
  for ext in "$@"; do
    echo "  [default] - $ext"
    "$code_bin" --uninstall-extension "$ext" >/dev/null 2>&1 \
      || echo "    (already gone: $ext)"
  done
}

echo "==> Flutter profile (Dart-Code official, modern only)"
install_in_profile "Flutter" \
  Dart-Code.dart-code \
  Dart-Code.flutter \
  Nash.awesome-flutter-snippets \
  robert-brunhage.flutter-riverpod-snippets \
  usernamehw.errorlens \
  pflannery.vscode-versionlens \
  editorconfig.editorconfig \
  vscodevim.vim \
  eamodio.gitlens \
  anthropic.claude-code \
  github.copilot-chat \
  ms-ceintl.vscode-language-pack-pt-br

echo "==> iOS / Swift profile"
install_in_profile "iOS" \
  swiftlang.swift-vscode \
  sweetpad.sweetpad \
  vadimcn.vscode-lldb \
  stevemoser.xcode-keybindings \
  usernamehw.errorlens \
  vscodevim.vim \
  eamodio.gitlens \
  anthropic.claude-code \
  github.copilot-chat \
  ms-ceintl.vscode-language-pack-pt-br

echo "==> Python profile"
install_in_profile "Python" \
  ms-python.python \
  ms-python.vscode-pylance \
  ms-python.debugpy \
  usernamehw.errorlens \
  vscodevim.vim \
  eamodio.gitlens \
  anthropic.claude-code \
  github.copilot-chat \
  ms-ceintl.vscode-language-pack-pt-br

echo "==> Web profile (TS / React / Tailwind)"
install_in_profile "Web" \
  dbaeumer.vscode-eslint \
  esbenp.prettier-vscode \
  bradlc.vscode-tailwindcss \
  formulahendry.auto-rename-tag \
  christian-kohler.path-intellisense \
  christian-kohler.npm-intellisense \
  usernamehw.errorlens \
  vscodevim.vim \
  eamodio.gitlens \
  anthropic.claude-code \
  github.copilot-chat \
  ms-ceintl.vscode-language-pack-pt-br

echo "==> Ruby / Rails profile"
install_in_profile "Ruby" \
  shopify.ruby-lsp \
  rubocop.vscode-rubocop \
  kaiwood.endwise \
  aliariff.vscode-erb-beautify \
  bung87.rails \
  bung87.vscode-gemfile \
  sianglim.slim \
  vscodevim.vim \
  eamodio.gitlens \
  anthropic.claude-code

echo "==> LaTeX profile"
install_in_profile "LaTeX" \
  james-yu.latex-workshop \
  tecosaur.latex-utilities \
  valentjn.vscode-ltex \
  vscodevim.vim \
  eamodio.gitlens \
  anthropic.claude-code

echo "==> C/C++ profile"
install_in_profile "Cpp" \
  ms-vscode.cpptools \
  ms-vscode.cmake-tools \
  ms-vscode.makefile-tools \
  vadimcn.vscode-lldb \
  usernamehw.errorlens \
  vscodevim.vim \
  eamodio.gitlens \
  anthropic.claude-code

echo "==> Strudel profile"
install_in_profile "Strudel" \
  cmillsdev.strudelvs \
  vscodevim.vim \
  eamodio.gitlens \
  ms-ceintl.vscode-language-pack-pt-br

echo
echo "==> Pruning DEFAULT profile (vim-first core only)"
# Drop: duplicate/deprecated, domain-specific (now in profiles), excess themes, dead AIs.
uninstall_default \
  Dart-Code.dart-code \
  Dart-Code.flutter \
  Nash.awesome-flutter-snippets \
  robert-brunhage.flutter-riverpod-snippets \
  pflannery.vscode-versionlens \
  swiftlang.swift-vscode \
  sweetpad.sweetpad \
  vadimcn.vscode-lldb \
  stevemoser.xcode-keybindings \
  ms-python.python \
  ms-python.vscode-pylance \
  ms-python.debugpy \
  ms-python.vscode-python-envs \
  dbaeumer.vscode-eslint \
  esbenp.prettier-vscode \
  bradlc.vscode-tailwindcss \
  formulahendry.auto-rename-tag \
  christian-kohler.npm-intellisense \
  ionutvmi.path-autocomplete \
  ecmel.vscode-html-css \
  shopify.ruby-lsp \
  rubocop.vscode-rubocop \
  misogi.ruby-rubocop \
  kaiwood.endwise \
  aliariff.vscode-erb-beautify \
  bung87.rails \
  bung87.vscode-gemfile \
  sianglim.slim \
  aki77.rails-db-schema \
  hridoy.rails-snippets \
  vense.rails-snippets \
  castwide.solargraph \
  connorshea.vscode-ruby-test-adapter \
  koichisasada.vscode-rdbg \
  onlyno2.rspec-runner \
  benspaulding.procfile \
  james-yu.latex-workshop \
  tecosaur.latex-utilities \
  valentjn.vscode-ltex \
  ms-vscode.cpptools \
  ms-vscode.cpptools-extension-pack \
  ms-vscode.cpptools-themes \
  ms-vscode.cmake-tools \
  ms-vscode.makefile-tools \
  mitaki28.vscode-clang \
  llvm-vs-code-extensions.lldb-dap \
  justusadam.language-haskell \
  moozzyk.arduino \
  cmillsdev.strudelvs \
  deep2universe.strudel-box \
  mateuszluczak.strudel \
  hbenl.vscode-test-explorer \
  ms-vscode.test-adapter-converter \
  erikdombi.peeky-xray \
  kiranshah.chatgpt-helper \
  rubberduck.rubberduck-vscode \
  openai.chatgpt \
  ms-vscode.vscode-speech \
  ms-azuretools.vscode-containers \
  arcticicestudio.nord-visual-studio-code \
  dracula-theme.theme-dracula \
  enkia.tokyo-night \
  jdinhlife.gruvbox \
  jovejonovski.ocean-green \
  monokai.theme-monokai-pro-vscode \
  qufiwefefwoyn.kanagawa \
  shadesofbuntu.flexoki-light \
  tahayvr.matteblack \
  cleanthemes.matte-black-theme \
  ms-ceintl.vscode-language-pack-pt-br

echo
echo "==> Default profile final extension list:"
"$code_bin" --list-extensions

echo
echo "Done. Open a profile with:  code --profile Flutter ."
