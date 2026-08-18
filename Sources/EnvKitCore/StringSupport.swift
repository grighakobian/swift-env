extension String {
    /// Trims spaces and tabs from both ends.
    ///
    /// Hand-rolled rather than using `Foundation.trimmingCharacters(in:)` so
    /// this target stays Foundation-free and usable from a build plugin.
    func trimmingASCIIWhitespace() -> String {
        var characters = Substring(self)
        while let first = characters.first, first == " " || first == "\t" {
            characters = characters.dropFirst()
        }
        while let last = characters.last, last == " " || last == "\t" {
            characters = characters.dropLast()
        }
        return String(characters)
    }
}
