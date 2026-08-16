defmodule Gitility.Identity do
  @moduledoc """
  An author or committer identity, preserved exactly as Git encoded it.

  `name` and `email` are raw bytes — Git makes no encoding promise, and
  Gitility makes none either. `time` is Unix seconds; `tz` is the raw
  timezone field exactly as encoded (e.g. `"+1000"`, including the `-0000`
  that some tools emit). Log results additionally populate
  `tz_offset_minutes` with the parsed numeric offset.

  `display_name/1` and `to_datetime/1` are the lossy conveniences.
  """

  @enforce_keys [:name, :email, :time, :tz]
  defstruct [:name, :email, :time, :tz, :tz_offset_minutes]

  @type t :: %__MODULE__{
          name: binary(),
          email: binary(),
          time: integer(),
          tz: binary(),
          tz_offset_minutes: integer() | nil
        }

  @doc "The name as a printable string (lossy — see `Gitility.Path.display/1`)."
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{name: name}), do: Gitility.Path.display(name)

  @doc """
  The identity's timestamp as a UTC `DateTime`.

  Deliberately UTC-only: representing the original local offset would
  require inventing a timezone, and `-0000` has no integer representation
  at all. The exact original offset stays available in `tz`; combine the
  two when local wall time matters.
  """
  @spec to_datetime(t()) :: {:ok, DateTime.t()} | {:error, Gitility.Error.t()}
  def to_datetime(%__MODULE__{time: time}) do
    case DateTime.from_unix(time) do
      {:ok, datetime} ->
        {:ok, datetime}

      {:error, _} ->
        {:error,
         Gitility.Error.new(:malformed_object, "identity timestamp outside DateTime range")}
    end
  end

  @doc """
  The identity's UTC offset in seconds, parsed from the raw `tz` field.

  Returns `{:ok, seconds, negative_zero?}` — `negative_zero?` is true for
  the `-0000` encoding some tools emit, which means "offset unknown" rather
  than UTC.
  """
  @spec utc_offset(t()) :: {:ok, integer(), boolean()} | {:error, Gitility.Error.t()}
  def utc_offset(%__MODULE__{tz: <<sign, h1, h2, m1, m2>>})
      when sign in [?+, ?-] and h1 in ?0..?9 and h2 in ?0..?9 and m1 in ?0..?9 and m2 in ?0..?9 do
    minutes = (h1 - ?0) * 600 + (h2 - ?0) * 60 + (m1 - ?0) * 10 + (m2 - ?0)
    seconds = minutes * 60

    case sign do
      ?- -> {:ok, -seconds, seconds == 0}
      ?+ -> {:ok, seconds, false}
    end
  end

  def utc_offset(%__MODULE__{}) do
    {:error, Gitility.Error.new(:malformed_object, "unparseable timezone field in identity")}
  end
end
