# Release notes

Voges Word now opens **Markdown**, *with* ~~some~~ formatting, `inline code`
and [links](https://example.com/notes?a=1&b=2 "Notes").

## Lists

- First
- Second
  - Nested
- [x] Done
- [ ] Pending

3. Three
4. Four

> Quoted text
> that continues.

| Feature | Status |
| :------ | -----: |
| Tables  | Yes    |
| Pipes   | a \| b |

```dart
void main() {
  print('hi');
}
```

Line one\
line two.

---

Footnote reference[^1] and an image: ![dot](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==)

<span style="color: red">Inline HTML</span> and <script>alert(1)</script> stay safe.

[^1]: The note.
