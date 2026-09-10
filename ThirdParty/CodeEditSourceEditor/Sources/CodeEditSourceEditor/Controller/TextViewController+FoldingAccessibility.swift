import AppKit

extension TextViewController {
    /// Supply host-localized labels without baking application copy into the
    /// editor package. VoiceOver uses the same action as the native gutter.
    public func configureFoldingAccessibility(actionName: String, hint: String) {
        gutterView.foldingRibbon.toolTip = hint
        textView.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: actionName) { [weak self] in
                guard let self,
                      let line = self.textView.layoutManager.textLineForOffset(self.textView.selectedRange().location),
                      let fold = self.gutterView.foldingRibbon.model?.getCachedFoldAt(lineNumber: line.index)
                else { return false }
                self.gutterView.foldingRibbon.toggleFold(fold)
                return true
            }
        ])
    }
}
