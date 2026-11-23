# Audited device tests

One `<TestClass>.txt` per audited `EpubToMp3Tests` class (device selectors are validated against these files).

- A line `* whole class` allows the selector `EpubToMp3Tests/<Class>`; without it only the listed methods may run.
- One test method name per line, sorted, so concurrent branches that audit different classes never touch the same
  file and branches that add methods to one class only conflict on that class's file.
- `#` starts a comment.
