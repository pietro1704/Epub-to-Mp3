# Zsh completion for python_app/convert
# Add to ~/.zshrc: source /path/to/Epub-to-Mp3/shell-completion.zsh

_epub_convert() {
  local -a args
  args=(
    '1:epub file:_files -g "*.{epub,pdf}"'
    '--engine[TTS engine]:engine:(auto edge coqui piper)'
    '--voice[Voice name]:voice:'
    '--chapter[Chapter number]:chapter:'
    '--priority[Priority chapter]:priority:'
    '--show-structure[Show book structure]'
    '--clear-cache[Clear cache]'
    '--menu[Interactive menu]'
    '--no-footnote[Skip footnotes]'
    '-y[Assume yes]'
    '--verbose[Verbose output]'
  )
  _arguments -s -S $args
}

# Register completion for both relative and absolute paths
compdef _epub_convert python_app/convert
compdef _epub_convert ./python_app/convert
