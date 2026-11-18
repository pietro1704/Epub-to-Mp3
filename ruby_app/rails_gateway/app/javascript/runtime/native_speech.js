// A single Web Speech engine serves the page. Playback is owned by the current
// job/chapter selection and publishes presentation only. It has no conversion API.
function pickVoice(voices, language, requested) {
  const normalize = (tag) => tag.toLowerCase().replaceAll("_", "-")
  const locale = normalize(language)
  const compatible = voices.filter((voice) => {
    const lang = normalize(voice.lang)
    return voice.localService && (lang === locale || lang.split("-")[0] === locale)
  })
  if (requested) return compatible.find(voice => voice.name === requested || voice.voiceURI === requested)
  const luciana = voice => normalize(voice.lang) === "pt-br" && /luciana/i.test(voice.name)
  return compatible.sort((a, b) => Number(luciana(b)) - Number(luciana(a)) || a.voiceURI.localeCompare(b.voiceURI))[0]
}

export class NativeSpeech {
  constructor(synthesis, utterance = text => new SpeechSynthesisUtterance(text)) {
    this.synthesis = synthesis
    this.utterance = utterance
    this.listeners = new Set()
    this.state = null
  }

  subscribe(listener) {
    this.listeners.add(listener)
    listener(this.state)
    return () => this.listeners.delete(listener)
  }

  publish(value) {
    this.state = value
    for (const listener of this.listeners) listener(value)
  }

  stop(owner) {
    if (!this.session || this.session.owner !== owner) return
    const session = this.session
    this.session = null
    this.clear(session)
    if (session.speaking) this.synthesis.cancel()
    if (this.state?.phase === "paused") this.synthesis.resume()
    this.publish(null)
  }

  clear(session) {
    clearTimeout(session.timer)
    if (session.voicesChanged) {
      this.synthesis.removeEventListener("voiceschanged", session.voicesChanged)
      session.voicesChanged = null
    }
    if (session.utterance) {
      session.utterance.onstart = session.utterance.onend = session.utterance.onerror = null
      session.utterance = null
    }
  }

  start(owner, text, policy) {
    if (this.session) this.stop(this.session.owner)
    const session = this.session = { owner, speaking: false }
    this.publish({ owner, phase: "starting", voice: "" })
    if (!this.synthesis) return this.finish(session, "unavailable")
    // Match the React client: keep each utterance within the browser's
    // practical speech limit and retain every whitespace character.
    session.chunks = text.matchAll(/[\s\S]{1,400}(?:\s|$)|[\s\S]{1,400}/g)
    const begin = () => {
      if (this.session !== session) return true
      const voice = pickVoice(this.synthesis.getVoices(), policy.language, policy.voice)
      if (!voice) return false
      this.clear(session)
      session.voice = voice
      document.querySelectorAll("audio").forEach(audio => audio.pause())
      this.speakNext(session)
      return true
    }
    if (begin()) return
    session.voicesChanged = begin
    this.synthesis.addEventListener("voiceschanged", begin)
    session.timer = setTimeout(() => { if (!begin()) this.finish(session, "unavailable") }, 1500)
  }

  finish(session, phase) {
    if (this.session !== session) return
    this.clear(session)
    session.speaking = false
    this.publish({ ...this.state, phase })
  }

  speakNext(session) {
    this.clear(session)
    const part = session.chunks.next()
    if (part.done) return this.finish(session, "completed")
    const utterance = session.utterance = this.utterance(part.value[0])
    utterance.voice = session.voice
    utterance.lang = session.voice.lang
    const current = () => this.session === session && session.utterance === utterance
    utterance.onstart = () => {
      if (current()) this.publish({ owner: session.owner, phase: "playing", voice: session.voice.name + " (" + session.voice.lang + ")" })
    }
    utterance.onend = () => { if (current()) this.speakNext(session) }
    utterance.onerror = () => { if (current()) this.finish(session, "failed") }
    session.remaining = 120_000
    session.speaking = true
    this.armTimeout(session)
    try {
      this.synthesis.speak(utterance)
    } catch {
      this.finish(session, "failed")
    }
  }

  armTimeout(session) {
    session.started = Date.now()
    session.timer = setTimeout(() => {
      if (this.session !== session) return
      this.finish(session, "failed")
      this.synthesis.cancel()
    }, session.remaining)
  }

  togglePause(owner) {
    const session = this.session
    if (!session || session.owner !== owner) return
    if (this.state.phase === "playing") {
      clearTimeout(session.timer)
      session.remaining = Math.max(0, session.remaining - (Date.now() - session.started))
      this.synthesis.pause()
      this.publish({ ...this.state, phase: "paused" })
    } else if (this.state.phase === "paused") {
      this.synthesis.resume()
      this.armTimeout(session)
      this.publish({ ...this.state, phase: "playing" })
    }
  }
}

let engine
export function browserNativeSpeech() {
  return engine ??= new NativeSpeech(window.speechSynthesis)
}
