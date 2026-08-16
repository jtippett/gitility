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

    /// Returns true if `prefix` itself or anything below it can match.
    ///
    /// Literal pathspecs admit exact pruning. Glob pathspecs use the complete
    /// directory portion before their first metacharacter as a conservative
    /// fast path; patterns without such a directory prefix keep the walk
    /// open. This never rejects a subtree that the matcher could select.
    pub(crate) fn may_match_descendant(&self, prefix: &[u8]) -> bool {
        self.patterns.is_empty()
            || self
                .patterns
                .iter()
                .any(|pattern| pattern_may_match_descendant(pattern, prefix))
    }
}

fn pattern_may_match_descendant(pattern: &[u8], prefix: &[u8]) -> bool {
    let (pattern, force_glob) = pattern
        .strip_prefix(b":(glob)")
        .map_or((pattern, false), |pattern| (pattern, true));
    let first_meta = pattern
        .iter()
        .position(|byte| matches!(byte, b'*' | b'?' | b'['));
    if !force_glob && first_meta.is_none() {
        return path_prefixes_overlap(pattern, prefix);
    }

    let fixed = &pattern[..first_meta.unwrap_or(pattern.len())];
    let Some(last_slash) = fixed.iter().rposition(|byte| *byte == b'/') else {
        return true;
    };
    path_prefixes_overlap(&fixed[..last_slash], prefix)
}

fn path_prefixes_overlap(left: &[u8], right: &[u8]) -> bool {
    left == right
        || (left.starts_with(right) && left.get(right.len()) == Some(&b'/'))
        || (right.starts_with(left) && right.get(left.len()) == Some(&b'/'))
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

    #[test]
    fn descendant_check_prunes_literal_and_fixed_glob_prefixes_conservatively() {
        let literal = PathspecMatcher::new(&[b"dir/sub/file.txt".to_vec()]);
        assert!(literal.may_match_descendant(b"dir"));
        assert!(literal.may_match_descendant(b"dir/sub"));
        assert!(!literal.may_match_descendant(b"other"));

        let glob = PathspecMatcher::new(&[b":(glob)dir/sub/**".to_vec()]);
        assert!(glob.may_match_descendant(b"dir"));
        assert!(glob.may_match_descendant(b"dir/sub"));
        assert!(!glob.may_match_descendant(b"other"));

        let root_glob = PathspecMatcher::new(&[b"*.txt".to_vec()]);
        assert!(root_glob.may_match_descendant(b"anywhere"));
    }
}
