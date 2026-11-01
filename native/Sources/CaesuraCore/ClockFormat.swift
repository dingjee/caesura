import Foundation

/// Converts the legacy Luxon `DateTime.toFormat` token string into an ICU pattern
/// that `DateFormatter` understands.
///
/// Luxon and ICU disagree on several tokens — most importantly on the macro tokens:
///
/// - `t` / `tt` / `T` / `TT` are locale aware time macros in Luxon, but `t` is not a
///   valid ICU pattern letter at all (passing it through would raise an
///   Objective-C exception inside `DateFormatter`).
/// - `D` is a locale aware short date macro in Luxon ("10/26/2026"), while ICU's `D`
///   is the day of the month. The documented legacy format "cccc, D, tt" therefore
///   means "weekday, short date, time with seconds" — not "weekday, day of month".
///
/// Tokens without an ICU equivalent are emitted as quoted literals, so the produced
/// pattern is always a valid ICU pattern.
public enum ClockFormat {
    private enum Token {
        case literal(String)
        case token(String)
    }

    /// The ICU pattern for a legacy Luxon format string.
    public static func icuPattern(fromLuxon format: String) -> String {
        let tokens = tokenize(format)
        var result = ""
        for token in tokens {
            switch token {
            case .literal(let text):
                result += quote(text)
            case .token(let text):
                if let mapped = pattern(for: text) {
                    result += mapped
                } else {
                    result += quote(text)
                }
            }
        }
        return result.isEmpty ? defaultPattern : result
    }

    /// A `DateFormatter` for a legacy Luxon format string.
    public static func formatter(fromLuxon format: String, locale: Locale = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar.current
        formatter.dateFormat = icuPattern(fromLuxon: format)
        return formatter
    }

    // MARK: - Tokenizing (mirrors Luxon's parseFormat)

    private static func tokenize(_ format: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        var token = ""
        var inQuotes = false
        var justEnteredQuotes = false

        func flushToken() {
            if !token.isEmpty { tokens.append(.token(token)); token = "" }
        }
        func flushLiteral() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }

        for character in format {
            if character == "'" {
                if inQuotes {
                    if justEnteredQuotes {
                        // An escaped quote ('') is a literal apostrophe.
                        literal.append("'")
                        justEnteredQuotes = false
                        continue
                    }
                    flushLiteral()
                    inQuotes = false
                } else {
                    flushToken()
                    flushLiteral()
                    inQuotes = true
                    justEnteredQuotes = true
                }
                continue
            }
            if inQuotes {
                literal.append(character)
                continue
            }
            if character.isLetter {
                // A letter starts a token: the pending literal comes first.
                flushLiteral()
                if let last = token.last, last == character {
                    token.append(character)
                } else {
                    flushToken()
                    token = String(character)
                }
                continue
            }
            // Everything that is not a letter is a literal: the pending token comes first.
            flushToken()
            literal.append(character)
        }
        flushToken()
        flushLiteral()
        return tokens
    }

    // MARK: - Token mapping

    private static var uses24HourClock: Bool {
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current)
        guard let template else { return false }
        return template.contains("H") || template.contains("k")
    }

    private static var shortTimePattern: String {
        uses24HourClock ? "HH:mm" : "h:mm a"
    }

    private static var timeWithSecondsPattern: String {
        uses24HourClock ? "HH:mm:ss" : "h:mm:ss a"
    }

    private static var defaultPattern: String { timeWithSecondsPattern }

    /// Maps a Luxon token onto an ICU pattern; nil when the token has no equivalent.
    private static func pattern(for token: String) -> String? {
        switch token {
        // Luxon macro tokens
        case "D": return "M/d/y"
        case "DD": return "MMM d, y"
        case "DDD": return "EEEE, MMMM d, y"
        case "DDDD": return "EEEE, G y, MMMM d"
        case "t": return shortTimePattern
        case "tt": return timeWithSecondsPattern
        case "ttt": return timeWithSecondsPattern + " z"
        case "tttt": return timeWithSecondsPattern + " zzzz"
        case "T": return "HH:mm"
        case "TT": return "HH:mm:ss"
        case "TTT": return "HH:mm:ss z"
        case "TTTT": return "HH:mm:ss zzzz"
        case "f": return "M/d/y, " + shortTimePattern
        case "ff": return "MMM d, y, " + shortTimePattern
        case "fff": return "EEEE, MMMM d, y, " + shortTimePattern
        case "ffff": return "EEEE, G y, MMMM d, " + shortTimePattern
        case "F": return "M/d/y, " + timeWithSecondsPattern
        case "FF": return "MMM d, y, " + timeWithSecondsPattern
        case "FFF": return "EEEE, MMMM d, y, " + timeWithSecondsPattern
        case "FFFF": return "EEEE, G y, MMMM d, " + timeWithSecondsPattern
        // Luxon micro tokens
        case "S": return "S"
        case "SSS": return "SSS"
        case "u": return "S"
        case "uu": return "SS"
        case "uuu": return "SSS"
        case "s": return "s"
        case "ss": return "ss"
        case "m": return "m"
        case "mm": return "mm"
        case "h": return "h"
        case "hh": return "hh"
        case "H": return "H"
        case "HH": return "HH"
        case "a": return "a"
        case "d": return "d"
        case "dd": return "dd"
        case "c": return "c"
        case "ccc": return "EEE"
        case "cccc": return "EEEE"
        case "ccccc": return "EEEEE"
        case "E": return "E"
        case "EEE": return "EEE"
        case "EEEE": return "EEEE"
        case "EEEEE": return "EEEEE"
        case "L": return "L"
        case "LL": return "LL"
        case "LLL": return "LLL"
        case "LLLL": return "LLLL"
        case "LLLLL": return "LLLLL"
        case "M": return "M"
        case "MM": return "MM"
        case "MMM": return "MMM"
        case "MMMM": return "MMMM"
        case "MMMMM": return "MMMMM"
        case "y": return "y"
        case "yy": return "yy"
        case "yyyy": return "yyyy"
        case "yyyyy": return "yyyyy"
        case "yyyyyy": return "yyyyyy"
        case "G": return "G"
        case "GG": return "GG"
        case "GGGGG": return "GGGGG"
        case "Z": return "Z"
        case "ZZ": return "ZZ"
        case "ZZZ": return "ZZZ"
        case "ZZZZ": return "OOOO"
        case "ZZZZZ": return "OOOO"
        case "z": return "z"
        case "kk": return "YY"
        case "kkkk": return "YYYY"
        case "W": return "w"
        case "WW": return "ww"
        case "n": return "w"
        case "nn": return "ww"
        case "i": return "Y"
        case "iiii": return "YYYY"
        case "q": return "Q"
        case "qq": return "QQ"
        case "X": return "X"
        case "x": return "x"
        default:
            return nil
        }
    }

    /// Quotes a literal run so ICU treats every character as a literal.
    ///
    /// Consecutive letters are quoted as one section (ICU would read them as pattern
    /// letters); punctuation and whitespace are literal in ICU patterns and stay raw.
    /// Two quoted sections must never be adjacent: ICU reads `''` as an escaped
    /// apostrophe, which showed up as a stray apostrophe in the rendered time.
    private static func quote(_ text: String) -> String {
        var result = ""
        var letters = ""

        func flushLetters() {
            guard !letters.isEmpty else { return }
            result += "'" + letters.replacingOccurrences(of: "'", with: "''") + "'"
            letters = ""
        }

        for character in text {
            if character.isLetter {
                letters.append(character)
                continue
            }
            flushLetters()
            if character == "'" {
                result += "''"
            } else {
                result.append(character)
            }
        }
        flushLetters()
        return result
    }
}
