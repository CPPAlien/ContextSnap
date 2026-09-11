import Foundation

/// Turns the LaTeX that agents sprinkle into answers ($v_i = \omega \times X_i$)
/// into readable Unicode (vᵢ = ω × Xᵢ) before the Markdown pass runs.
///
/// This is deliberately not a TeX engine: no layout, no fractions stacked over
/// a rule. It covers what shows up in a chat reply — Greek letters, operators,
/// sub/superscripts, simple fractions and roots — and leaves anything it does
/// not understand readable rather than mangled.
enum MathText {
    /// Replaces every math span in `source`. Inline code spans are skipped so
    /// `` `$HOME` `` survives untouched.
    static func render(_ source: String) -> String {
        var out = ""
        var rest = Substring(source)

        while let start = rest.firstIndex(where: { $0 == "$" || $0 == "\\" || $0 == "`" }) {
            out += rest[rest.startIndex..<start]
            rest = rest[start...]

            // Inline code: copy through to the closing backtick.
            if rest.first == "`" {
                let afterTick = rest.index(after: rest.startIndex)
                if let close = rest[afterTick...].firstIndex(of: "`") {
                    out += rest[rest.startIndex...close]
                    rest = rest[rest.index(after: close)...]
                } else {
                    out += rest
                    rest = rest[rest.endIndex...]
                }
                continue
            }

            if let span = matchDelimited(rest) {
                out += convert(span.body)
                rest = rest[span.end...]
                continue
            }

            // Not a math span (a lone "$", an escaped "\$", a stray backslash):
            // emit the character and carry on.
            if rest.hasPrefix("\\$") {
                out += "$"
                rest = rest[rest.index(rest.startIndex, offsetBy: 2)...]
            } else {
                out.append(rest.first!)
                rest = rest[rest.index(after: rest.startIndex)...]
            }
        }
        out += rest
        return out
    }

    private struct Span {
        let body: String
        /// Index just past the closing delimiter.
        let end: Substring.Index
    }

    private static let delimiters: [(open: String, close: String)] = [
        ("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$"),
    ]

    private static func matchDelimited(_ s: Substring) -> Span? {
        for (open, close) in delimiters {
            guard s.hasPrefix(open) else { continue }
            let bodyStart = s.index(s.startIndex, offsetBy: open.count)
            guard let closeRange = s[bodyStart...].range(of: close) else { continue }
            let body = String(s[bodyStart..<closeRange.lowerBound])
            guard looksLikeMath(body, singleDollar: open == "$") else { continue }
            return Span(body: body, end: closeRange.upperBound)
        }
        return nil
    }

    /// `$` is also money and shell syntax, so a single-dollar span has to look
    /// mathematical: no line break, no padding spaces, and either a TeX
    /// command / sub / superscript / relation, or a very short symbol.
    private static func looksLikeMath(_ body: String, singleDollar: Bool) -> Bool {
        guard !body.isEmpty, body.count <= 400, !body.contains("\n") else { return false }
        guard !body.hasPrefix(" "), !body.hasSuffix(" ") else { return false }
        guard singleDollar else { return true }
        if body.contains(where: { "\\_^=<>+".contains($0) }) { return true }
        return body.count <= 3 && body.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: LaTeX → Unicode

    private static func convert(_ tex: String) -> String {
        var s = tex

        // Spacing and grouping commands that carry no meaning here.
        for command in ["\\left", "\\right", "\\displaystyle", "\\limits"] {
            s = s.replacingOccurrences(of: command, with: "")
        }
        for thinSpace in ["\\!", "\\,", "\\;", "\\:"] {
            s = s.replacingOccurrences(of: thinSpace, with: " ")
        }
        s = s.replacingOccurrences(of: "\\\\", with: "\n")

        s = replacingCommand(s, "frac", arguments: 2) { args in
            let (a, b) = (args[0], args[1])
            let needsParens = { (t: String) in t.contains(where: { " +-".contains($0) }) }
            return (needsParens(a) ? "(\(a))" : a) + "/" + (needsParens(b) ? "(\(b))" : b)
        }
        s = replacingCommand(s, "dfrac", arguments: 2) { "\($0[0])/\($0[1])" }
        s = replacingCommand(s, "sqrt", arguments: 1) { "√(\($0[0]))" }
        for unwrapped in ["text", "mathrm", "mathbf", "mathit", "operatorname", "mathbb", "mathcal"] {
            s = replacingCommand(s, unwrapped, arguments: 1) { $0[0] }
        }
        s = replacingCommand(s, "hat", arguments: 1) { $0[0] + "\u{0302}" }
        s = replacingCommand(s, "bar", arguments: 1) { $0[0] + "\u{0304}" }
        s = replacingCommand(s, "vec", arguments: 1) { $0[0] + "\u{20D7}" }
        s = replacingCommand(s, "dot", arguments: 1) { $0[0] + "\u{0307}" }

        s = replacingSymbols(s)
        s = replacingScripts(s, marker: "^", table: superscripts)
        s = replacingScripts(s, marker: "_", table: subscripts)

        // Leftover grouping braces and unknown commands: keep the name, drop
        // the backslash, so "\foo" reads as "foo" instead of vanishing.
        s = s.replacingOccurrences(of: "{", with: "")
        s = s.replacingOccurrences(of: "}", with: "")
        s = s.replacingOccurrences(of: "\\", with: "")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Rewrites `\name{a}{b}` spans using `body`, innermost occurrences first.
    private static func replacingCommand(_ source: String,
                                         _ name: String,
                                         arguments: Int,
                                         body: ([String]) -> String) -> String {
        var s = source
        var guardCount = 0
        while let range = s.range(of: "\\" + name), guardCount < 200 {
            guardCount += 1
            var cursor = range.upperBound
            var args: [String] = []
            for _ in 0..<arguments {
                guard let arg = readGroup(s, from: &cursor) else { break }
                args.append(arg)
            }
            guard args.count == arguments else {
                // Malformed: strip the command name so the loop terminates.
                s.replaceSubrange(range, with: name)
                continue
            }
            s.replaceSubrange(range.lowerBound..<cursor, with: body(args))
        }
        return s
    }

    /// Reads `{…}` (balanced) or a single following character.
    private static func readGroup(_ s: String, from cursor: inout String.Index) -> String? {
        while cursor < s.endIndex, s[cursor] == " " { cursor = s.index(after: cursor) }
        guard cursor < s.endIndex else { return nil }
        if s[cursor] == "{" {
            var depth = 0
            var i = cursor
            while i < s.endIndex {
                if s[i] == "{" { depth += 1 }
                if s[i] == "}" {
                    depth -= 1
                    if depth == 0 {
                        let body = String(s[s.index(after: cursor)..<i])
                        cursor = s.index(after: i)
                        return body
                    }
                }
                i = s.index(after: i)
            }
            return nil
        }
        // A bare token: "\frac12" or "x^2".
        let ch = s[cursor]
        cursor = s.index(after: cursor)
        return String(ch)
    }

    private static func replacingSymbols(_ source: String) -> String {
        var s = source
        // Longest first so \varphi wins over \var, \Theta over \Th, etc.
        for name in symbols.keys.sorted(by: { $0.count > $1.count }) {
            guard s.contains("\\" + name) else { continue }
            let symbol = symbols[name]!
            // TeX needs a space to end a command name ("\\partial t"); for a
            // symbol that stands in for a value that space is punctuation, not
            // layout, so drop it: "∂t", not "∂ t". Operators keep their
            // breathing room ("ω × Xᵢ").
            if operands.contains(name) {
                s = s.replacingOccurrences(of: "\\\\" + name + " +(?=[A-Za-z0-9(])",
                                           with: symbol,
                                           options: .regularExpression)
            }
            s = s.replacingOccurrences(of: "\\" + name, with: symbol)
        }
        return s
    }

    /// Commands that read as a value rather than an operator.
    private static let operands: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta",
        "eta", "theta", "vartheta", "iota", "kappa", "lambda", "mu", "nu",
        "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi", "varphi", "chi",
        "psi", "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi",
        "Sigma", "Upsilon", "Phi", "Psi", "Omega",
        "partial", "nabla", "infty", "sum", "prod", "int", "sqrt",
    ]

    /// `x^2`, `X_i`, `v_{max}` → Unicode scripts when every character has one;
    /// otherwise the marker is kept so the meaning survives.
    private static func replacingScripts(_ source: String, marker: Character, table: [Character: Character]) -> String {
        var out = ""
        var i = source.startIndex
        while i < source.endIndex {
            guard source[i] == marker else {
                out.append(source[i]); i = source.index(after: i); continue
            }
            var cursor = source.index(after: i)
            guard let group = readGroup(source, from: &cursor) else {
                out.append(source[i]); i = source.index(after: i); continue
            }
            let mapped = group.compactMap { table[$0] }
            if !group.isEmpty, mapped.count == group.count {
                out += String(mapped)
            } else {
                out.append(marker)
                out += group.count > 1 ? "(\(group))" : group
            }
            i = cursor
        }
        return out
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
        "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽",
        ")": "⁾", "n": "ⁿ", "i": "ⁱ", "T": "ᵀ", "x": "ˣ", "y": "ʸ", "a": "ᵃ",
        "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "k": "ᵏ", "m": "ᵐ", "t": "ᵗ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆",
        "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍",
        ")": "₎", "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ",
        "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    private static let symbols: [String: String] = [
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators and relations
        "times": "×", "cdot": "·", "cdots": "⋯", "ldots": "…", "div": "÷",
        "pm": "±", "mp": "∓", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼",
        "propto": "∝", "ll": "≪", "gg": "≫",
        // Calculus and sets
        "partial": "∂", "nabla": "∇", "infty": "∞", "int": "∫", "iint": "∬",
        "oint": "∮", "sum": "Σ", "prod": "Π", "sqrt": "√", "forall": "∀",
        "exists": "∃", "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆",
        "cup": "∪", "cap": "∩", "emptyset": "∅", "mathbb{R}": "ℝ",
        // Arrows and misc
        "to": "→", "rightarrow": "→", "Rightarrow": "⇒", "leftarrow": "←",
        "Leftarrow": "⇐", "leftrightarrow": "↔", "mapsto": "↦",
        "circ": "∘", "otimes": "⊗", "oplus": "⊕", "perp": "⊥", "angle": "∠",
        "deg": "°", "degree": "°", "prime": "′", "quad": "  ", "qquad": "    ",
    ]
}
