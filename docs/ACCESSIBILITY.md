# Accessibility

herdrm is used with VoiceOver, dictation apps and inline autocomplete tools, all
of which read the app through the macOS accessibility API. A control they can't
find or name is a control those users don't have. These rules apply to the
macOS app and to HerdrMobile.

Apple's references:

- [Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Accessibility Programming Guide for OS X](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/)
- [SwiftUI accessibility modifiers](https://developer.apple.com/documentation/swiftui/view-accessibility)

## Rules

1. **Every control has its own name.** VoiceOver reads what the control does,
   never its icon. The New Space header button used to be announced as "New
   Folder", after its SF Symbol (fixed in 0.6.11, #109).
2. **Rows that aren't `Button`s still act like buttons.** Sidebar Space, Agent
   and Terminal rows carry `.accessibilityAddTraits(.isButton)` and an
   `.accessibilityAction` that selects the row, so VoiceOver's Activate works
   (0.6.0, #71).
3. **A row's label must not replace the controls inside it.** An
   `.accessibilityLabel` on a container is applied to the controls inside it,
   so a chevron or button in that row is then read by the row's name. Put the
   row's label on the row content only and give inner controls their own
   names. Example: the grouped-mode chevron on a space row was read as the
   space's name instead of "Collapse space".
4. **Disclosures say whether they're open.** Use `disclosureAccessibility(expanded:)`
   in `SidebarView.swift`; macOS SwiftUI has no `accessibilityExpanded`, so it
   sets the value to Expanded / Collapsed.
5. **Text surfaces expose their text.** The terminal reports itself as a text
   area with its visible text, selection and cursor position (0.6.8, 0.6.10),
   so dictation and autocomplete tools can work at the caret. Keep that when
   changing the terminal view.

## Testing

- Find controls the way VoiceOver does, by role and name, with
  `Tests/HerdrMTests/AccessibilityProbe.swift`. Assert on the names users hear.
- Test clicks with mouse events that go through AppKit hit-testing, as
  `SidebarHarness` does. An accessibility press (`AXPress`) runs the control's
  action directly and passes even when another view covers the control and
  takes every real click.
