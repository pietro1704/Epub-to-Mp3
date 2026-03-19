# Zsh completion for python_app/convert
# Add to ~/.zshrc: source /path/to/Epub-to-Mp3/shell-completion.zsh

_epub_convert() {
  local -a args
  args=(
    '1:epub file:_files -g "*.{epub,pdf}"'
    '--engine[TTS engine]:engine:(auto edge coqui piper kokoro spark)'
    '--voice[Voice name]:voice:'
    '--chapter[Chapter number]:chapter:'
    '--priority[Priority chapter]:priority:'
    '--language[Primary language override]:language:'
    '--use-language-detection[Enable language markup]'
    '--no-language-detection[Disable language markup]'
    '--prioritize-primary-language[Prefer primary language on ambiguity]'
    '--no-prioritize-primary-language[Do not prefer primary language]'
    '--ui-language[CLI language (pt or en)]:ui-language:'
    '--show-structure[Show book structure]'
    '--clear-cache[Clear cache]'
    '--resume-from-failure[Retry only failed chapters from checkpoint]'
    '--no-resume-from-failure[Ignore failure checkpoint]'
    '--force-reprocess[Ignore cached audio]'
    '--menu[Interactive menu]'
    '--no-footnote[Skip footnotes]'
    '--max-performance[Use aggressive performance defaults]'
    '--profile[Predefined profile]:profile:(speed)'
    '--speed-scenario[Scenario for speed profile]:speed-scenario:(auto balanced edge-fast offline-heavy)'
    '--parallel-slots[Override parallel chapters]:parallel-slots:'
    '--edge-chunk-chars[Edge chunk size]:edge-chunk-chars:'
    '--edge-max-segment-seconds[Edge max segment seconds]:edge-max-segment-seconds:'
    '--edge-enable-parallel[Enable Edge parallelism]'
    '--edge-disable-parallel[Disable Edge parallelism]'
    '--edge-auto-tune[Enable Edge auto tune]'
    '--no-edge-auto-tune[Disable Edge auto tune]'
    '--coqui-chunk-chars[Coqui chunk size]:coqui-chunk-chars:'
    '--coqui-max-workers[Coqui max workers]:coqui-max-workers:'
    '--coqui-safe-mode[Enable Coqui safe mode]'
    '--no-coqui-safe-mode[Disable Coqui safe mode]'
    '--piper-max-procs[Piper max processes]:piper-max-procs:'
    '--bitrate[Output bitrate]:bitrate:'
    '--sample-rate[Output sample rate]:sample-rate:'
    '--channels[Output channels]:channels:'
    '--health-check-interval-seconds[Healthcheck interval (server)]:health-check-interval-seconds:'
    '--health-check-slow-edge-cps[Healthcheck slow Edge cps]:health-check-slow-edge-cps:'
    '--health-check-slow-cps[Healthcheck slow cps]:health-check-slow-cps:'
    '--health-check-high-cpu[Healthcheck high CPU]:health-check-high-cpu:'
    '--health-check-high-mem[Healthcheck high mem]:health-check-high-mem:'
    '--health-check-ok-cpu[Healthcheck ok CPU]:health-check-ok-cpu:'
    '--health-check-ok-mem[Healthcheck ok mem]:health-check-ok-mem:'
    '--health-check-slow-streak[Healthcheck slow streak]:health-check-slow-streak:'
    '--show-metrics-summary[Show runtime metrics summary at end]'
    '--show-metrics-dashboard[Show metrics dashboard path at end]'
    '--open-metrics-dashboard[Open metrics dashboard in browser at end]'
    '--export-metrics-bundle[Export metrics files as ZIP at end]'
    '--prefetch[Enable chapter prefetch]'
    '--no-prefetch[Disable chapter prefetch]'
    '--ab-auto[Enable auto-engine A/B exploration]'
    '--no-ab-auto[Disable auto-engine A/B exploration]'
    '--adaptive-checkpoint[Enable adaptive state checkpoint]'
    '--no-adaptive-checkpoint[Disable adaptive state checkpoint]'
    '-y[Assume yes]'
    '--verbose[Verbose output]'
  )
  _arguments -s -S $args
}

# Register completion for both relative and absolute paths
compdef _epub_convert python_app/convert
compdef _epub_convert ./python_app/convert
compdef _epub_convert convert
compdef _epub_convert ./convert
