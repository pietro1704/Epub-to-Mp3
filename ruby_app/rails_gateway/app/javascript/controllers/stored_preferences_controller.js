import { Controller } from "@hotwired/stimulus"

const SEEDED_FLAG = "ebook-tts-preferences-seeded"

/**
 * Bridges the cookies Rails reads with the localStorage keys the React client
 * wrote. A stored choice is submitted once on the first visit, and every
 * choice made here is written back so both clients stay in agreement.
 */
export default class extends Controller {
  static targets = ["form"]

  connect() {
    const pending = this.formTargets
      .map((form) => ({ form, value: storedChoice(form) }))
      .filter((entry) => entry.value)
    if (pending.length === 0 || !claimSeed()) return

    // One request carries every stored preference: concurrent Turbo form
    // submissions would cancel each other.
    const [first, ...others] = pending
    for (const { form, value } of others) first.form.append(hiddenField(form.dataset.preference, value))
    first.form.requestSubmit(choiceButton(first.form, first.value))
  }

  /** @param {SubmitEvent} event */
  remember(event) {
    const { submitter, currentTarget } = event
    if (submitter instanceof HTMLButtonElement && submitter.name) {
      writeStorage(localStorage, /** @type {HTMLFormElement} */ (currentTarget).dataset.storageKey, submitter.value)
    }
  }
}

/** @param {HTMLFormElement} form */
function storedChoice(form) {
  if (form.dataset.chosen === "true") return null
  const stored = readStorage(localStorage, form.dataset.storageKey)
  return stored && stored !== form.dataset.mode && choiceButton(form, stored) ? stored : null
}

/**
 * @param {HTMLFormElement} form
 * @param {string} value
 */
function choiceButton(form, value) {
  return Array.from(form.querySelectorAll("button[name]")).find((button) => button.value === value) ?? null
}

/**
 * @param {string} name
 * @param {string} value
 */
function hiddenField(name, value) {
  const field = document.createElement("input")
  field.type = "hidden"
  field.name = name
  field.value = value
  return field
}

/** Seeds at most once per tab, so a browser that refuses cookies cannot loop. */
function claimSeed() {
  if (readStorage(sessionStorage, SEEDED_FLAG)) return false
  return writeStorage(sessionStorage, SEEDED_FLAG, "true")
}

/**
 * @param {Storage} storage
 * @param {string} key
 */
function readStorage(storage, key) {
  try {
    return storage.getItem(key)
  } catch {
    return null
  }
}

/**
 * @param {Storage} storage
 * @param {string} key
 * @param {string} value
 */
function writeStorage(storage, key, value) {
  try {
    storage.setItem(key, value)
    return true
  } catch {
    return false
  }
}
