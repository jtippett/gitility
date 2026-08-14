defmodule Gitility.NotImplementedError do
  @moduledoc """
  Raised by API stubs that are specified but not yet implemented.

  This exception exists only during Gitility's pre-1.0 build-out: the public
  API is encoded (specs, docs, types) ahead of the engine, milestone by
  milestone. It never appears in a function whose milestone has shipped, and
  it will be deleted entirely once the surface is complete.
  """

  defexception [:message]

  @doc false
  @spec stub!(atom(), String.t()) :: no_return()
  def stub!(fun, milestone) do
    raise __MODULE__,
      message:
        "Gitility.#{fun} is specified but not yet implemented (lands in #{milestone} — " <>
          "see docs/plans/2026-08-14-gitility-design.md)"
  end
end
