//! Byte-oriented Git pathspec filters.
//!
//! Callers match paths relative to the listing scope, just as Git resolves a
//! pathspec relative to its current working directory. Patterns containing
//! `*`, `?`, or `[` use path-aware wildmatch rules. A pattern without those
//! metacharacters is a literal prefix: it selects that exact path and every
//! path beneath it.

use bstr::ByteSlice;
use gix_glob::wildmatch;

/// A set of OR-ed Git wildmatch patterns.
#[derive(Debug, Clone)]
pub(crate) struct PathspecMatcher {
    patterns: Vec<Vec<u8>>,
}

impl PathspecMatcher {
    pub(crate) fn new(patterns: &[Vec<u8>]) -> Self {
        Self {
            patterns: patterns.to_vec(),
        }
    }

    pub(crate) fn matches(&self, path: &[u8]) -> bool {
        self.patterns.is_empty() || self.patterns.iter().any(|pattern| matches(pattern, path))
    }
}

/// Matches one raw-byte path with Git's path-aware wildmatch rules.
///
/// A single `*` never crosses `/`; a path-positioned `**` may. The explicit
/// `:(glob)` magic used by Git's CLI is accepted and selects these same
/// path-aware glob rules.
pub fn matches(pattern: &[u8], path: &[u8]) -> bool {
    let (pattern, force_glob) = pattern
        .strip_prefix(b":(glob)")
        .map_or((pattern, false), |pattern| (pattern, true));
    if !force_glob
        && !pattern
            .iter()
            .any(|byte| matches!(byte, b'*' | b'?' | b'['))
    {
        return path == pattern
            || (path.starts_with(pattern) && path.get(pattern.len()) == Some(&b'/'));
    }
    gix_glob::wildmatch(
        pattern.as_bstr(),
        path.as_bstr(),
        wildmatch::Mode::NO_MATCH_SLASH_LITERAL,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn star_does_not_cross_slash_but_double_star_does() {
        let star = PathspecMatcher::new(&[b"*.txt".to_vec()]);
        assert!(star.matches(b"root.txt"));
        assert!(!star.matches(b"src/nested.txt"));

        let double_star = PathspecMatcher::new(&[b"**/*.txt".to_vec()]);
        assert!(double_star.matches(b"root.txt"));
        assert!(double_star.matches(b"src/nested.txt"));
        assert!(!double_star.matches(b"src/nested.rs"));
    }

    #[test]
    fn matches_raw_non_utf8_bytes() {
        let matcher = PathspecMatcher::new(&[b"invalid-?-name.txt".to_vec()]);
        assert!(matcher.matches(b"invalid-\xff-name.txt"));
    }

    #[test]
    fn literal_patterns_select_the_exact_path_and_its_descendants() {
        let matcher = PathspecMatcher::new(&[b"lib".to_vec()]);
        assert!(matcher.matches(b"lib"));
        assert!(matcher.matches(b"lib/gitility.ex"));
        assert!(!matcher.matches(b"library"));
        assert!(!matcher.matches(b"src/lib"));
    }

    #[test]
    fn explicit_glob_magic_is_supported() {
        let matcher = PathspecMatcher::new(&[b":(glob)sub/**".to_vec()]);
        assert!(matcher.matches(b"sub/file"));
        assert!(matcher.matches(b"sub/deep/file"));
        assert!(!matcher.matches(b"outside/file"));
    }
}
