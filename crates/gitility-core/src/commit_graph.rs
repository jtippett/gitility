//! Adapter from Gitility's object-store and budget contracts to gitoxide's
//! plumbing traversal traits.

use crate::budget::Budget;
use crate::error::{Error, ErrorCode};
use crate::lru::LruCache;
use crate::object::{HashKind, ObjectKind, Oid};
use crate::odb::ObjectDb;
use std::cell::RefCell;
use std::rc::Rc;

const PAYLOAD_CACHE_BYTES: u64 = 4 * 1024 * 1024;

#[derive(Clone)]
pub(crate) struct GixFind<'a> {
    state: Rc<RefCell<State<'a>>>,
}

struct State<'a> {
    store: &'a dyn ObjectDb,
    budget: &'a Budget,
    objects: LruCache<Oid, (ObjectKind, Vec<u8>)>,
    first_error: Option<Error>,
    current_oid: Option<Oid>,
}

impl<'a> GixFind<'a> {
    pub(crate) fn new(store: &'a dyn ObjectDb, budget: &'a Budget) -> Self {
        Self {
            state: Rc::new(RefCell::new(State {
                store,
                budget,
                objects: LruCache::new(PAYLOAD_CACHE_BYTES),
                first_error: None,
                current_oid: None,
            })),
        }
    }

    pub(crate) fn validate_commit(&self, oid: Oid) -> Result<(), Error> {
        let (kind, _) = self.object(oid)?;
        if kind != ObjectKind::Commit {
            return Err(Error::new(
                ErrorCode::NotACommit,
                format!("object {oid} is not a commit"),
            )
            .with_oid(oid));
        }
        Ok(())
    }

    pub(crate) fn clear_error_scope(&self) {
        let mut state = self.state.borrow_mut();
        state.first_error = None;
        state.current_oid = None;
    }

    pub(crate) fn take_error_or(&self, code: ErrorCode, message: &'static str) -> Error {
        let mut state = self.state.borrow_mut();
        state.first_error.take().unwrap_or_else(|| {
            let error = Error::new(code, message);
            match state.current_oid {
                Some(oid) => error.with_oid(oid),
                None => error,
            }
        })
    }

    fn object(&self, oid: Oid) -> Result<(ObjectKind, Vec<u8>), Error> {
        let mut state = self.state.borrow_mut();
        state.budget.check()?;
        state.current_oid = Some(oid);
        if let Some((kind, payload)) = state.objects.get_cloned(&oid) {
            return Ok((kind, payload));
        }

        let mut payload = Vec::new();
        let kind = match state.store.try_find(&oid, &mut payload, state.budget) {
            Ok(Some(kind)) => kind,
            Ok(None) => {
                let error = missing(oid);
                record_first_error(&mut state, &error);
                return Err(error);
            }
            Err(error) => {
                let error = error.with_oid_if_none(oid);
                record_first_error(&mut state, &error);
                return Err(error);
            }
        };
        if kind == ObjectKind::Commit
            && state
                .store
                .shallow_roots()
                .is_some_and(|roots| roots.contains(&oid))
        {
            payload = without_parent_headers(&payload);
        }
        state
            .objects
            .insert(oid, (kind, payload.clone()), payload.len() as u64);
        Ok((kind, payload))
    }
}

fn without_parent_headers(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len());
    let mut in_headers = true;
    for line in payload.split_inclusive(|byte| *byte == b'\n') {
        if in_headers && line == b"\n" {
            in_headers = false;
        }
        if in_headers && line.starts_with(b"parent ") {
            continue;
        }
        out.extend_from_slice(line);
    }
    out
}

impl gix_object::Find for GixFind<'_> {
    fn try_find<'a>(
        &self,
        id: &gix_hash::oid,
        buffer: &'a mut Vec<u8>,
    ) -> Result<Option<gix_object::Data<'a>>, gix_object::find::Error> {
        let oid = from_gix_oid(id).map_err(|error| {
            record_first_error(&mut self.state.borrow_mut(), &error);
            Box::new(error) as gix_object::find::Error
        })?;
        let (kind, payload) = self.object(oid).map_err(|error| {
            record_first_error(&mut self.state.borrow_mut(), &error);
            Box::new(error) as gix_object::find::Error
        })?;
        buffer.clear();
        buffer.extend_from_slice(&payload);
        Ok(Some(gix_object::Data::new(
            buffer,
            to_gix_object_kind(kind),
            to_gix_hash(oid.kind()),
        )))
    }
}

pub(crate) fn ensure_sha1(store: &dyn ObjectDb, oids: &[Oid]) -> Result<(), Error> {
    if store.hash_kind() == HashKind::Sha256 {
        return Err(Error::new(
            ErrorCode::UnsupportedHash,
            "SHA-256 query execution not yet supported",
        ));
    }
    if oids.iter().any(|oid| oid.kind() != store.hash_kind()) {
        return Err(Error::new(
            ErrorCode::InvalidOid,
            "commit object ID algorithm does not match the object store",
        ));
    }
    Ok(())
}

pub(crate) fn to_gix_oid(oid: Oid) -> Result<gix_hash::ObjectId, Error> {
    gix_hash::ObjectId::try_from(oid.as_bytes()).map_err(|_| {
        Error::new(
            ErrorCode::InvalidOid,
            "object ID cannot be represented by the commit graph engine",
        )
    })
}

pub(crate) fn from_gix_oid(oid: &gix_hash::oid) -> Result<Oid, Error> {
    let kind = match oid.kind() {
        gix_hash::Kind::Sha1 => HashKind::Sha1,
        gix_hash::Kind::Sha256 => HashKind::Sha256,
        _ => {
            return Err(Error::new(
                ErrorCode::UnsupportedHash,
                "commit graph engine returned an unsupported hash algorithm",
            ))
        }
    };
    Oid::new(kind, oid.as_bytes())
}

fn to_gix_hash(kind: HashKind) -> gix_hash::Kind {
    match kind {
        HashKind::Sha1 => gix_hash::Kind::Sha1,
        HashKind::Sha256 => gix_hash::Kind::Sha256,
    }
}

fn to_gix_object_kind(kind: ObjectKind) -> gix_object::Kind {
    match kind {
        ObjectKind::Commit => gix_object::Kind::Commit,
        ObjectKind::Tree => gix_object::Kind::Tree,
        ObjectKind::Blob => gix_object::Kind::Blob,
        ObjectKind::Tag => gix_object::Kind::Tag,
    }
}

fn record_first_error(state: &mut State<'_>, error: &Error) {
    if state.first_error.is_none() {
        state.first_error = Some(error.clone());
    }
}

fn missing(oid: Oid) -> Error {
    Error::retryable(
        ErrorCode::MissingObject,
        format!("commit object {oid} is missing from the object store"),
    )
    .with_oid(oid)
}
