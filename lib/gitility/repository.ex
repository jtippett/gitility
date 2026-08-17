defmodule Gitility.Repository do
  @moduledoc """
  A repository is just an ODB plus an optional RefDB.

  It exists to resolve *selectors* — names for commits — into pinned
  `Gitility.Snapshot`s. Nothing else in the library takes a repository:
  every query takes a snapshot, and a snapshot needs only an ODB and a
  commit ID.

  ## Selectors

  Safe selectors resolve a name through the repository's stores:

      {:oid, oid_or_hex}       # no refs needed
      {:ref, "refs/pull/481/head"}
      {:branch, "main"}        # expands to refs/heads/main
      {:tag, "v1.2.0"}         # expands to refs/tags/…, peels annotated tags
      :head

  `{:revspec, string}` is reserved for a future opt-in advanced selector.
  Gitility 0.x always rejects it with `:unsupported_operation`.
  """

  alias Gitility.{Error, Native, NativeSupport, ODB, OID, RefDB, RefTarget, Snapshot}

  @typedoc "A repository handle: object store plus optional ref store."
  @type t :: %__MODULE__{odb: ODB.t(), refs: RefDB.t() | nil}

  @enforce_keys [:odb]
  defstruct [:odb, :refs]

  @typedoc "A commit selector — see the moduledoc."
  @type selector ::
          {:oid, OID.t() | String.t()}
          | {:ref, binary()}
          | {:branch, binary()}
          | {:tag, binary()}
          | :head
          | {:revspec, String.t()}

  @doc """
  Opens a local repository directory — bare or normal, though queries never
  read worktree files either way.

  ## Options

    * `:require_bare` — reject a non-bare repository (default `false`).
    * `:object_cache_bytes` — native object cache ceiling (default 64 MiB).
    * `:verify_pack_checksums` — deep-check pack and index checksums before
      the first object read (default `false`).
    * `:runtime` — the `Gitility.Runtime` to attach to (default: shared).

  ## Example

      {:ok, repo} =
        Gitility.Repository.open("/srv/git/acme/widgets.git", require_bare: true)

      {:ok, snapshot} = Gitility.Repository.snapshot(repo, {:branch, "main"})
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(path, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        require_bare: false,
        object_cache_bytes: 64 * 1024 * 1024,
        verify_pack_checksums: false,
        runtime: :default
      )

    unless is_binary(path) do
      raise ArgumentError, "expected repository path to be a binary"
    end

    require_bare = NativeSupport.boolean_option!(opts, :require_bare)
    verify_pack_checksums = NativeSupport.boolean_option!(opts, :verify_pack_checksums)

    _object_cache_bytes = opts[:object_cache_bytes]

    with {:ok, runtime, _runtime_resource} <-
           NativeSupport.runtime_and_resource(opts[:runtime]) do
      case Native.open_local(path, %{
             require_bare: require_bare,
             verify_pack_checksums: verify_pack_checksums
           }) do
        {:ok, {resource, ref_resource, hash}} ->
          odb = %ODB{kind: :local, ref: resource, hash: hash, runtime: runtime}
          refs = %RefDB{kind: :local, ref: ref_resource, runtime: runtime}
          {:ok, %__MODULE__{odb: odb, refs: refs}}

        {:error, error} ->
          {:error, NativeSupport.nif_error(error, :repository_open)}
      end
    end
  end

  @doc """
  Composes independently-created stores into a repository. The stores must
  share a runtime (`:runtime_mismatch` otherwise).

  ## Options

    * `:odb` (required) — a `Gitility.ODB` handle.
    * `:refs` — a `Gitility.RefDB` handle; omit for an ODB-only repository
      (only `{:oid, _}` selectors will resolve).
  """
  @spec from_stores(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_stores(stores) do
    stores = Keyword.validate!(stores, odb: nil, refs: nil)

    case {stores[:odb], stores[:refs]} do
      {%ODB{} = odb, nil} ->
        {:ok, %__MODULE__{odb: odb, refs: nil}}

      {%ODB{} = odb, %RefDB{} = refs} when odb.runtime == refs.runtime ->
        {:ok, %__MODULE__{odb: odb, refs: refs}}

      {%ODB{}, %RefDB{}} ->
        {:error,
         Error.new(:runtime_mismatch, "object and reference stores use different runtimes",
           operation: :repository_from_stores
         )}

      {nil, _refs} ->
        NativeSupport.invalid_argument(":odb is required")

      {_odb, _refs} ->
        NativeSupport.invalid_argument(
          ":odb must be a Gitility.ODB and :refs must be a Gitility.RefDB or nil"
        )
    end
  end

  @doc """
  Resolves a selector and pins it as an immutable snapshot.

  Resolution happens once, here: the returned snapshot records the commit
  and root tree IDs and never moves, no matter what the underlying refs do
  afterwards.
  """
  @spec snapshot(t(), selector(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def snapshot(repo, selector, opts \\ [])

  def snapshot(%__MODULE__{odb: odb}, {:oid, oid}, opts) do
    opts = Keyword.validate!(opts, limits: nil)
    Snapshot.open(odb, oid, opts)
  end

  def snapshot(%__MODULE__{} = repo, {:ref, name}, opts) when is_binary(name) do
    snapshot_from_ref(repo, name, :direct, opts)
  end

  def snapshot(%__MODULE__{} = repo, {:branch, name}, opts) when is_binary(name) do
    snapshot_from_ref(repo, <<"refs/heads/", name::binary>>, :direct, opts)
  end

  def snapshot(%__MODULE__{} = repo, {:tag, name}, opts) when is_binary(name) do
    snapshot_from_ref(repo, <<"refs/tags/", name::binary>>, :peel, opts)
  end

  def snapshot(%__MODULE__{} = repo, :head, opts) do
    snapshot_from_ref(repo, "HEAD", :direct, opts)
  end

  def snapshot(%__MODULE__{}, {:revspec, revspec}, opts) when is_binary(revspec) do
    _opts = Keyword.validate!(opts, limits: nil)

    {:error,
     Error.new(
       :unsupported_operation,
       "advanced revspec selectors are unavailable in Gitility 0.x",
       operation: :repository_snapshot,
       details: %{capability: :revspec}
     )}
  end

  def snapshot(%__MODULE__{}, _selector, opts) do
    _opts = Keyword.validate!(opts, limits: nil)
    NativeSupport.invalid_argument("selector is not a supported safe selector")
  end

  defp snapshot_from_ref(%__MODULE__{refs: nil}, _name, _mode, opts) do
    _opts = Keyword.validate!(opts, limits: nil)

    {:error,
     Error.new(:unsupported_operation, "repository has no reference store",
       operation: :repository_snapshot,
       details: %{capability: :refs}
     )}
  end

  defp snapshot_from_ref(%__MODULE__{odb: odb, refs: refs}, name, mode, opts) do
    opts = Keyword.validate!(opts, limits: nil)

    case RefDB.resolve(refs, name, opts) do
      {:ok, :not_found} ->
        {:error,
         Error.new(:ref_not_found, "reference was not found",
           operation: :repository_snapshot,
           details: %{ref: name}
         )}

      {:ok, %RefTarget{kind: :direct} = target} ->
        oid = if mode == :peel, do: target.peeled || target.oid, else: target.oid

        if oid.algorithm != odb.hash do
          {:error,
           Error.new(:hash_mismatch, "reference target hash does not match the object store",
             operation: :repository_snapshot,
             details: %{ref: name, ref_hash: oid.algorithm, odb_hash: odb.hash}
           )}
        else
          if mode == :peel do
            Snapshot.open(odb, oid, opts)
          else
            Snapshot.open_direct(odb, oid, opts)
          end
        end

      {:ok, %RefTarget{kind: :symbolic}} ->
        {:error,
         Error.new(:provider_protocol_error, "reference resolution returned an unfollowed target",
           operation: :repository_snapshot
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end
end
