use std::path::PathBuf;

/// Binary classification policy for gix-diff blob conversion.
pub(crate) enum BinaryPolicy {
    Detect,
    ForceText,
}

/// Build the shared blob/rewrite platform used by structured diff and blame.
///
/// Structured diff keeps gitoxide's automatic NUL-byte classification. Blame
/// selects a synthetic attribute-backed driver that forces text semantics so
/// gix-blame can attribute raw-byte lines exactly as canonical Git does.
pub(crate) fn platform(
    max_object_bytes: u64,
    binary_policy: BinaryPolicy,
) -> gix_diff::blob::Platform {
    let (drivers, attributes) = match binary_policy {
        BinaryPolicy::Detect => (
            Vec::new(),
            attributes(gix_worktree::stack::State::AttributesStack(
                Default::default(),
            )),
        ),
        BinaryPolicy::ForceText => {
            const DRIVER: &str = "gitility-blame-text";
            let mut collection = gix_worktree::attributes::search::MetadataCollection::default();
            let mut globals = gix_worktree::attributes::Search::new_globals(
                std::iter::empty::<PathBuf>(),
                &mut Vec::new(),
                &mut collection,
            )
            .expect("an empty global-attribute file list cannot fail");
            globals.add_patterns_buffer(
                format!("* diff={DRIVER}").as_bytes(),
                PathBuf::from("[gitility blame text override]"),
                None,
                &mut collection,
                true,
            );
            let state = gix_worktree::stack::state::Attributes::new(
                globals,
                None,
                gix_worktree::stack::state::attributes::Source::IdMapping,
                collection,
            );
            let driver = gix_diff::blob::Driver {
                name: DRIVER.into(),
                is_binary: Some(false),
                ..Default::default()
            };
            (
                vec![driver],
                attributes(gix_worktree::stack::State::AttributesStack(state)),
            )
        }
    };
    let pipeline = gix_diff::blob::Pipeline::new(
        Default::default(),
        Default::default(),
        drivers,
        gix_diff::blob::pipeline::Options {
            large_file_threshold_bytes: max_object_bytes,
            ..Default::default()
        },
    );
    gix_diff::blob::Platform::new(
        gix_diff::blob::platform::Options {
            algorithm: Some(gix_diff::blob::Algorithm::Histogram),
            ..Default::default()
        },
        pipeline,
        gix_diff::blob::pipeline::Mode::ToGit,
        attributes,
    )
}

fn attributes(state: gix_worktree::stack::State) -> gix_worktree::Stack {
    gix_worktree::Stack::new(
        PathBuf::new(),
        state,
        gix_worktree::glob::pattern::Case::Sensitive,
        Vec::new(),
        Vec::new(),
    )
}
