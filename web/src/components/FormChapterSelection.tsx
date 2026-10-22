import type { ConversionFormScope } from './useConversionFormController';

type FormChapterSelectionProps = Pick<
  ConversionFormScope,
  | 't'
  | 'isSubmitting'
  | 'chapters'
  | 'setChapters'
  | 'fromChapterToEnd'
  | 'setFromChapterToEnd'
  | 'fromChapterToChapter'
  | 'setFromChapterToChapter'
  | 'sections'
  | 'setSections'
  | 'priority'
  | 'setPriority'
  | 'footnoteMode'
  | 'setFootnoteMode'
>;

export function FormChapterSelection({
  t,
  isSubmitting,
  chapters,
  setChapters,
  fromChapterToEnd,
  setFromChapterToEnd,
  fromChapterToChapter,
  setFromChapterToChapter,
  sections,
  setSections,
  priority,
  setPriority,
  footnoteMode,
  setFootnoteMode,
}: FormChapterSelectionProps): JSX.Element {
  return (
    <>
      <fieldset className="form-row">
        <label htmlFor="chapters">{t.form.chaptersLabel}</label>
        <input
          id="chapters"
          name="chapters"
          placeholder={t.form.chaptersPlaceholder}
          value={chapters}
          disabled={isSubmitting}
          onChange={(event) => setChapters(event.target.value)}
        />
        <p className="form-hint">{t.form.chaptersHint}</p>
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="fromChapterToEnd">{t.form.fromChapterToEndLabel}</label>
        <input
          id="fromChapterToEnd"
          name="fromChapterToEnd"
          placeholder={t.form.fromChapterToEndPlaceholder}
          value={fromChapterToEnd}
          disabled={isSubmitting}
          onChange={(event) => setFromChapterToEnd(event.target.value)}
        />
        <p className="form-hint">{t.form.fromChapterToEndHint}</p>
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="fromChapterToChapter">{t.form.fromChapterToChapterLabel}</label>
        <input
          id="fromChapterToChapter"
          name="fromChapterToChapter"
          placeholder={t.form.fromChapterToChapterPlaceholder}
          value={fromChapterToChapter}
          disabled={isSubmitting}
          onChange={(event) => setFromChapterToChapter(event.target.value)}
        />
        <p className="form-hint">{t.form.fromChapterToChapterHint}</p>
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="sections">{t.form.sectionsLabel}</label>
        <input
          id="sections"
          name="sections"
          placeholder={t.form.sectionsPlaceholder}
          value={sections}
          disabled={isSubmitting}
          onChange={(event) => setSections(event.target.value)}
        />
        <p className="form-hint">{t.form.sectionsHint}</p>
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="priority">{t.form.priorityLabel}</label>
        <input
          id="priority"
          name="priority"
          placeholder={t.form.priorityPlaceholder}
          value={priority}
          disabled={isSubmitting}
          onChange={(event) => setPriority(event.target.value)}
        />
        <p className="form-hint">{t.form.priorityHint}</p>
      </fieldset>

      <fieldset className="form-field">
        <legend className="form-legend">{t.form.footnoteLegend}</legend>
        <div className="segmented-list">
          {t.form.footnoteOptions.map((option) => {
            const inputId = `footnote-${option.value}`;
            return (
              <label key={option.value} className="segmented-list__item" htmlFor={inputId}>
                <input
                  type="radio"
                  id={inputId}
                  name="footnoteMode"
                  value={option.value}
                  checked={footnoteMode === option.value}
                  disabled={isSubmitting}
                  onChange={() => setFootnoteMode(option.value)}
                />
                <span className="segmented-list__content">
                  <span className="segmented-list__title">{option.title}</span>
                  <span className="segmented-list__description">{option.description}</span>
                </span>
              </label>
            );
          })}
        </div>
      </fieldset>
    </>
  );
}
