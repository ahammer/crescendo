defmodule SymphonyElixir.Service do
  @moduledoc """
  Service configuration (`crescendo.yml`): one service runs several projects
  that share the worker slots, the daily budget and the Codex quota.

      server: {host: 0.0.0.0, port: 4280}
      paths: {state: ~/.local/state/crescendo}
      pool: {slots: 3}
      throttle: {daily_budget_usd: 200, backoff: [...]}
      pricing: {...}
      defaults: {codex: {routing: ...}}      # merged under every project's front matter
      projects:
        metalrain: {weight: 1, research_exclusive: global}
        nubu3d: {workflow: projects/nubu3d/WORKFLOW.md, redact: true}

  A project's workflow defaults to `projects/<id>/WORKFLOW.md` next to this
  file. `throttle` and `pricing` apply service-wide; `defaults` fills in
  anything a project's front matter leaves out, and the project's own values
  win. Everything is local configuration: the service is restarted to add or
  remove a project, while project workflows hot-reload as before.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema.{Pricing, Throttle}

  @primary_key false
  @id_format ~r/^[a-z0-9][a-z0-9-]*$/
  @exclusive ["none", "project", "global"]

  defmodule Helpers do
    @moduledoc "Service-wide limits for lease-free, read-only helper runs."
    use Ecto.Schema
    import Ecto.Changeset
    @primary_key false

    embedded_schema do
      field(:slots, :integer, default: 0)
      field(:model, :string, default: "gpt-6-luna")
      field(:effort, :string, default: "max")
      field(:timeout_ms, :integer, default: 900_000)
    end

    @type t :: %__MODULE__{}

    @spec changeset(struct(), map()) :: Ecto.Changeset.t()
    def changeset(settings, attrs) do
      settings
      |> cast(attrs, [:slots, :model, :effort, :timeout_ms])
      |> validate_required([:slots, :model, :effort, :timeout_ms])
      |> validate_number(:slots, greater_than_or_equal_to: 0, less_than_or_equal_to: 5)
      |> validate_number(:timeout_ms, greater_than: 0, less_than_or_equal_to: 900_000)
      |> validate_inclusion(:model, ["gpt-6-luna"])
      |> validate_inclusion(:effort, ["max"])
    end
  end

  defmodule QuietWindow do
    @moduledoc "Owner-confirmed recurring local acceptance window."
    use Ecto.Schema
    import Ecto.Changeset
    @primary_key false
    embedded_schema do
      field(:start, :string, default: "03:00")
      field(:end, :string, default: "04:00")
      field(:time_zone, :string, default: "America/Vancouver")
      field(:drain_minutes, :integer, default: 60)
    end

    @type t :: %__MODULE__{}

    @spec changeset(struct(), map()) :: Ecto.Changeset.t()
    def changeset(window, attrs) do
      window
      |> cast(attrs, [:start, :end, :time_zone, :drain_minutes])
      |> validate_required([:start, :end, :time_zone, :drain_minutes])
      |> validate_format(:start, ~r/\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z/)
      |> validate_format(:end, ~r/\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z/)
      |> validate_inclusion(:time_zone, ["America/Vancouver"])
      |> validate_number(:drain_minutes, greater_than_or_equal_to: 0, less_than_or_equal_to: 120)
      |> validate_order()
    end

    defp validate_order(changeset) do
      if get_field(changeset, :start) >= get_field(changeset, :end),
        do: add_error(changeset, :end, "must follow start on the same day"),
        else: changeset
    end

    @spec observe(t() | nil, DateTime.t()) :: map()
    def observe(nil, _now), do: %{phase: "idle"}

    def observe(window, now) do
      script = """
      import datetime, json, sys
      from zoneinfo import ZoneInfo
      epoch, start, end, zone, drain = sys.argv[1:]
      now = datetime.datetime.fromtimestamp(int(epoch), ZoneInfo(zone))
      begin = datetime.datetime.combine(now.date(), datetime.time.fromisoformat(start), now.tzinfo)
      finish = datetime.datetime.combine(now.date(), datetime.time.fromisoformat(end), now.tzinfo)
      phase = 'active' if begin <= now < finish else 'preparing' if begin - datetime.timedelta(minutes=int(drain)) <= now < begin else 'idle'
      midnight = datetime.datetime.combine(now.date() + datetime.timedelta(days=1), datetime.time(), now.tzinfo)
      print(json.dumps(dict(phase=phase, starts_at=int(begin.timestamp()), ends_at=int(finish.timestamp()), refresh_at=int(midnight.timestamp()), time_zone=zone)))
      """

      with {json, 0} <- System.cmd("python3", ["-c", script, to_string(DateTime.to_unix(now)), window.start, window.end, window.time_zone, to_string(window.drain_minutes)], stderr_to_stdout: true),
           {:ok, %{"phase" => phase, "starts_at" => begins, "ends_at" => ends, "refresh_at" => refresh, "time_zone" => zone}} <- Jason.decode(json) do
        %{phase: phase, starts_at: begins, ends_at: ends, refresh_at: refresh, time_zone: zone}
      else
        _ -> %{phase: "unknown"}
      end
    rescue
      _ -> %{phase: "unknown"}
    end
  end

  defmodule Project do
    @moduledoc "One project of the service."
    @enforce_keys [:id, :workflow]
    defstruct [:id, :workflow, :cap, weight: 1, research_exclusive: "project", enabled: true, redact: false, defaults: %{}]

    @type t :: %__MODULE__{
            id: String.t(),
            workflow: Path.t(),
            cap: pos_integer() | nil,
            weight: pos_integer(),
            research_exclusive: String.t(),
            enabled: boolean(),
            redact: boolean(),
            defaults: map()
          }
  end

  embedded_schema do
    field(:host, :string, default: "127.0.0.1")
    field(:port, :integer)
    field(:state_root, :string)
    field(:slots, :integer, default: 3)
    field(:defaults, :map, default: %{})
    field(:projects, :map, default: %{})
    embeds_one(:throttle, Throttle, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pricing, Pricing, on_replace: :update, defaults_to_struct: true)
    embeds_one(:helpers, Helpers, on_replace: :update, defaults_to_struct: true)
    embeds_one(:quiet_window, QuietWindow, on_replace: :update)
    field(:path, :string, virtual: true)
    field(:project_list, :any, virtual: true, default: [])
  end

  @type t :: %__MODULE__{}

  @doc "Reads and validates a service file."
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    path = Path.expand(path)

    with {:ok, content} <- read(path),
         {:ok, %{} = raw} <- decode(content, path) do
      parse(raw, path)
    end
  end

  @doc "Validates decoded service settings; relative paths resolve against `path`'s directory."
  @spec parse(map(), Path.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(raw, path) do
    attrs = flatten(raw)

    %__MODULE__{}
    |> cast(attrs, [:host, :port, :state_root, :slots, :defaults, :projects], empty_values: [])
    |> cast_embed(:throttle, with: &Throttle.changeset/2)
    |> cast_embed(:pricing, with: &Pricing.changeset/2)
    |> cast_embed(:helpers, with: &Helpers.changeset/2)
    |> cast_embed(:quiet_window, with: &QuietWindow.changeset/2)
    |> validate_number(:port, greater_than_or_equal_to: 0)
    |> validate_number(:slots, greater_than: 0)
    |> validate_projects()
    |> apply_action(:validate)
    |> case do
      {:ok, service} -> {:ok, finalize(service, raw, path)}
      {:error, changeset} -> {:error, errors(changeset)}
    end
  end

  @doc "Records the running service's configuration (set once at start)."
  @spec put_current(t()) :: :ok
  def put_current(%__MODULE__{} = service), do: :persistent_term.put({__MODULE__, :current}, service)

  @doc "The running service's configuration, or nil in the single-workflow runtime."
  @spec current() :: t() | nil
  def current, do: :persistent_term.get({__MODULE__, :current}, nil)

  @doc "Where the service keeps its state: operations history, the quota, the drain flag."
  @spec state_root(t()) :: Path.t()
  def state_root(%__MODULE__{state_root: root}) when is_binary(root), do: root
  def state_root(%__MODULE__{}), do: Path.expand("~/.local/state/crescendo")

  @doc "The enabled projects, in id order."
  @spec projects(t()) :: [Project.t()]
  def projects(%__MODULE__{project_list: projects}), do: Enum.filter(projects, & &1.enabled)

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(content, path) do
    case YamlElixir.read_from_string(content) do
      {:ok, %{} = raw} -> {:ok, raw}
      {:ok, _other} -> {:error, "#{path} must be a map"}
      {:error, error} -> {:error, "cannot parse #{path}: #{Exception.message(error)}"}
    end
  end

  # Nested YAML sections map onto flat fields: server.host, paths.state, pool.slots.
  defp flatten(raw) do
    %{
      "host" => get_in(raw, ["server", "host"]),
      "port" => get_in(raw, ["server", "port"]),
      "state_root" => get_in(raw, ["paths", "state"]),
      "slots" => get_in(raw, ["pool", "slots"]),
      "defaults" => raw["defaults"],
      "projects" => raw["projects"],
      "throttle" => raw["throttle"],
      "pricing" => raw["pricing"],
      "helpers" => raw["helpers"],
      "quiet_window" => raw["quiet_window"]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # An empty map equals the default, so this checks the field, not the change.
  defp validate_projects(changeset) do
    projects = get_field(changeset, :projects)

    cond do
      map_size(projects) == 0 ->
        add_error(changeset, :projects, "must name at least one project")

      Enum.all?(projects, fn {id, spec} -> is_binary(id) and Regex.match?(@id_format, id) and valid_project?(spec || %{}) end) ->
        changeset

      true ->
        add_error(changeset, :projects, "ids must be lowercase letters, digits, or dashes; see the project keys in the service docs")
    end
  end

  defp valid_project?(%{} = spec) do
    Map.keys(spec) -- ["workflow", "weight", "cap", "research_exclusive", "enabled", "redact"] == [] and
      Enum.all?(spec, fn {key, value} -> valid_project_value?(key, value) end)
  end

  defp valid_project?(_spec), do: false

  defp valid_project_value?(_key, nil), do: true
  defp valid_project_value?("workflow", value), do: is_binary(value) and String.trim(value) != ""
  defp valid_project_value?(key, value) when key in ["weight", "cap"], do: is_integer(value) and value > 0
  defp valid_project_value?("research_exclusive", value), do: value in @exclusive
  defp valid_project_value?(_flag, value), do: is_boolean(value)

  # Service pricing reaches every project (spend is priced where it is
  # recorded); relative paths resolve against the service file.
  defp finalize(service, raw, path) do
    dir = Path.dirname(path)
    defaults = if raw["pricing"], do: Map.put(service.defaults, "pricing", raw["pricing"]), else: service.defaults

    projects =
      service.projects
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, spec} -> project(id, spec || %{}, dir, defaults) end)

    %{service | path: path, state_root: service.state_root && Path.expand(service.state_root, dir), project_list: projects}
  end

  defp project(id, spec, dir, defaults) do
    %Project{
      id: id,
      workflow: Path.expand(spec["workflow"] || Path.join(["projects", id, "WORKFLOW.md"]), dir),
      weight: spec["weight"] || 1,
      cap: spec["cap"],
      research_exclusive: spec["research_exclusive"] || "project",
      enabled: Map.get(spec, "enabled", true),
      redact: Map.get(spec, "redact", false),
      defaults: defaults
    }
  end

  defp errors(changeset) do
    changeset
    |> traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(inspect(value))) end)
    end)
    |> Enum.flat_map(&error_lines/1)
    |> Enum.join(", ")
  end

  defp error_lines({key, %{} = nested}), do: Enum.flat_map(nested, fn {inner, value} -> error_lines({"#{key}.#{inner}", value}) end)
  defp error_lines({key, messages}), do: Enum.map(messages, &"#{key} #{&1}")
end
