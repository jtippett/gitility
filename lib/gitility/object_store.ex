defmodule Gitility.ObjectStore do
  @moduledoc """
  Behaviour for stores used by `Gitility.Mirror`.

  Object-store adapters publish a complete object atomically: readers see
  either the previous object or the complete replacement. `get/4` streams to
  exactly `dest_path <> ".part"` and renames that sibling into place only
  after the download succeeds, so a partial object never occupies
  `dest_path`. The caller owns both paths and is responsible for cleaning them
  after interruption.

  Keys are non-empty UTF-8 binaries of at most 1,024 bytes. They have no
  leading or trailing slash, NUL, empty path segment, or `.`/`..` segment.
  An adapter re-validates keys and returns `{:invalid_key, message}` when one
  is invalid. Every callback receives a positive `:timeout` in milliseconds
  and must return no later than one second after that budget expires.

  Adapter failures use the deliberately small, sanitised reason vocabulary
  in `t:reason/0`. In particular, HTTP errors retain only a status and a
  provider error-code string; transport and adapter classifications carry
  atoms, never request data or credentials. A raise, throw, exit, malformed
  callback return, or any other reason is treated as a bad adapter return by
  `Gitility.Mirror` and its original value is discarded.

  ## Conformance

  Adapter authors can exercise the common contract with the reusable case
  template:

      defmodule MyApp.ObjectStoreTest do
        use Gitility.ObjectStore.Conformance, store: MyApp.ObjectStore

        def store_init_arg, do: [root: fresh_store_root()]
      end

  See `Gitility.ObjectStore.Conformance` for its optional setup and slow-store
  hooks.
  """

  @type state :: term()
  @type key :: binary()
  @type etag :: binary()
  @type metadata :: %{optional(binary()) => binary()}
  @type head :: %{etag: etag(), size: non_neg_integer(), metadata: metadata()}

  @type reason ::
          {:unsupported_operation, binary()}
          | {:invalid_key, binary()}
          | {:transport, atom()}
          | {:http, 100..599, binary() | nil}
          | {:adapter, atom()}

  @callback init(init_arg :: term()) :: {:ok, state()} | {:error, reason()}

  @callback head(state(), key(), opts :: keyword()) ::
              {:ok, head()} | {:error, :not_found | reason()}

  @callback get(state(), key(), dest_path :: Path.t(), opts :: keyword()) ::
              {:ok, %{etag: etag(), bytes: non_neg_integer(), metadata: metadata()}}
              | {:error, :not_found | reason()}

  @callback put(state(), src_path :: Path.t(), key(), opts :: keyword()) ::
              {:ok, %{etag: etag()}} | {:error, :precondition_failed | reason()}
end
