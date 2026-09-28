defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false
  @linear_endpoint "https://api.linear.app/graphql"
  @linear_active_states ["Todo", "In Progress"]
  @linear_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string)
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:provider, :map, default: %{})
      field(:secret_environment_names, {:array, :string}, default: [])
      field(:required_labels, {:array, :string}, default: [])
      field(:excluded_labels, {:array, :string}, default: [])
      field(:active_states, {:array, :string})
      field(:terminal_states, {:array, :string})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_slug,
          :assignee,
          :provider,
          :required_labels,
          :excluded_labels,
          :active_states,
          :terminal_states
        ],
        empty_values: []
      )
      |> update_change(:required_labels, &normalize_labels/1)
      |> update_change(:excluded_labels, &normalize_labels/1)
    end

    defp normalize_labels(labels) do
      labels
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.uniq()
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_attempts, :integer)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_attempts, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:max_attempts, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")
      field(:routing, :map)

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :routing,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_change(:routing, fn :routing, routing ->
        case SymphonyElixir.ModelRouting.validate(routing) do
          :ok -> []
          {:error, reason} -> [routing: reason]
        end
      end)
      |> validate_change(:command, fn :command, command ->
        if command != "" and String.trim(command) == "" do
          [command: "can't be blank"]
        else
          []
        end
      end)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
      field(:daily_budget_usd, :float, default: 50.0)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms, :daily_budget_usd], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
      |> validate_number(:daily_budget_usd, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule Labels do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:prefix, :string, default: "symphony")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:prefix], empty_values: [])
      |> update_change(:prefix, &(&1 |> String.trim() |> String.downcase()))
      |> validate_format(:prefix, ~r/^[a-z0-9][a-z0-9-]*$/, message: "must be lowercase letters, digits, or dashes")
    end
  end

  defmodule Pricing do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:as_of, :string)
      field(:models, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:as_of, :models], empty_values: [])
      |> validate_change(:models, fn :models, models ->
        if Enum.all?(models, &valid_price?/1),
          do: [],
          else: [models: "must map model names to input, cached_input and output USD per million tokens"]
      end)
    end

    defp valid_price?({model, %{"input" => input, "cached_input" => cached, "output" => output} = price}) do
      is_binary(model) and map_size(price) == 3 and Enum.all?([input, cached, output], &(is_number(&1) and &1 >= 0))
    end

    defp valid_price?(_entry), do: false
  end

  defmodule Throttle do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:daily_budget_usd, :float)
      field(:over_budget_allow, {:array, :string}, default: ["pull_request", "final_attempt", "continuation"])
      field(:backoff, {:array, :map}, default: [])
      field(:quota_stale_ms, :integer, default: 7_200_000)
      field(:on_unknown_quota, :string, default: "restrict")
    end

    @classes ["research", "issue", "pull_request", "final_attempt", "continuation"]
    @rule_keys ["window", "remaining_below_percent", "avoid", "pause"]
    @fields [:daily_budget_usd, :over_budget_allow, :backoff, :quota_stale_ms, :on_unknown_quota]
    @rule_error "rules need a window, remaining_below_percent (0-100), and avoid (models) and/or pause: true"

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> validate_number(:daily_budget_usd, greater_than: 0)
      |> validate_subset(:over_budget_allow, @classes)
      |> validate_number(:quota_stale_ms, greater_than: 0)
      |> validate_inclusion(:on_unknown_quota, ["restrict", "allow"])
      |> validate_change(:backoff, fn :backoff, rules ->
        if Enum.all?(rules, &valid_rule?/1), do: [], else: [backoff: @rule_error]
      end)
    end

    defp valid_rule?(%{"window" => window, "remaining_below_percent" => percent} = rule)
         when is_binary(window) and is_number(percent) and percent > 0 and percent <= 100 do
      Map.keys(rule) -- @rule_keys == [] and valid_action?(Map.get(rule, "avoid", []), Map.get(rule, "pause", false))
    end

    defp valid_rule?(_rule), do: false

    defp valid_action?(avoid, pause) when is_list(avoid) and is_boolean(pause),
      do: Enum.all?(avoid, &(is_binary(&1) and String.trim(&1) != "")) and (pause or avoid != [])

    defp valid_action?(_avoid, _pause), do: false
  end

  defmodule Autopilot do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)

      field(:channels, :map,
        default: %{
          "cleanup" => "Dead code, duplication, unclear names, awkward or inconsistent APIs, and code that is hard to read.",
          "optimization" => "Measurable performance, resource, or cost wins, plus latent bugs found along the way.",
          "testing" => "Missing or weak tests for important behavior, flaky tests, and untested edge cases."
        }
      )

      field(:min_issues_per_channel, :integer, default: 1)
      field(:max_issues_per_channel, :integer, default: 3)
      field(:research_route, :map)
      field(:review_route, :map)
      field(:max_open_issues, :integer, default: 10)
      field(:research_cooldown_ms, :integer, default: 1_800_000)
      field(:max_pr_runs, :integer, default: 5)
      field(:pr_recheck_ms, :integer, default: 3_600_000)
      field(:max_item_attempts, :integer, default: 3)
      field(:blocked_label, :string, default: "symphony:blocked")
      field(:trusted_associations, {:array, :string}, default: ["OWNER", "MEMBER", "COLLABORATOR"])
      field(:trusted_authors, {:array, :string}, default: [])
      field(:prompts, :map, default: %{})
      # Derived from `labels.prefix`; not configured here.
      field(:label_prefix, :string, default: "symphony")
    end

    @prompt_kinds ["pull_request", "research"]
    @channel_name ~r/^[a-z0-9][a-z0-9-]*$/
    @channel_keys ["focus", "prompt", "min_issues", "max_issues", "route"]
    @channel_error "names must be lowercase letters, digits, or dashes and map to focus text or {focus, prompt, min_issues, max_issues, route}"

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :channels,
          :min_issues_per_channel,
          :max_issues_per_channel,
          :research_route,
          :review_route,
          :max_open_issues,
          :research_cooldown_ms,
          :max_pr_runs,
          :pr_recheck_ms,
          :max_item_attempts,
          :blocked_label,
          :trusted_associations,
          :trusted_authors,
          :prompts
        ],
        empty_values: []
      )
      |> validate_number(:min_issues_per_channel, greater_than: 0)
      |> validate_number(:max_issues_per_channel, greater_than: 0)
      |> validate_issue_range()
      |> validate_change(:research_route, &validate_fixed_route/2)
      |> validate_change(:review_route, &validate_fixed_route/2)
      |> validate_number(:max_open_issues, greater_than: 0)
      |> validate_number(:research_cooldown_ms, greater_than_or_equal_to: 0)
      |> validate_number(:max_pr_runs, greater_than: 0)
      |> validate_number(:pr_recheck_ms, greater_than_or_equal_to: 0)
      |> validate_number(:max_item_attempts, greater_than: 0)
      |> update_change(:blocked_label, &(&1 |> String.trim() |> String.downcase()))
      |> update_change(:trusted_associations, fn values -> Enum.map(values, &(String.trim(&1) |> String.upcase())) end)
      |> update_change(:trusted_authors, fn values -> Enum.map(values, &(String.trim(&1) |> String.downcase())) end)
      |> validate_change(:channels, &validate_channels/2)
      |> validate_channel_ranges()
      |> validate_change(:prompts, &validate_prompts/2)
    end

    defp validate_issue_range(changeset) do
      if get_field(changeset, :min_issues_per_channel) > get_field(changeset, :max_issues_per_channel),
        do: add_error(changeset, :min_issues_per_channel, "must not exceed max_issues_per_channel"),
        else: changeset
    end

    defp validate_channels(field, channels) do
      cond do
        map_size(channels) == 0 ->
          [{field, "must name at least one channel"}]

        Enum.all?(channels, fn {name, spec} -> Regex.match?(@channel_name, name) and valid_channel?(spec) end) ->
          []

        true ->
          [{field, @channel_error}]
      end
    end

    # A channel is its focus text, or an object that can also name its own
    # prompt file, issue counts and research route.
    defp valid_channel?(focus) when is_binary(focus), do: true

    defp valid_channel?(%{"focus" => focus} = spec) when is_binary(focus) do
      Map.keys(spec) -- @channel_keys == [] and
        (is_nil(spec["prompt"]) or (is_binary(spec["prompt"]) and String.trim(spec["prompt"]) != "")) and
        Enum.all?([spec["min_issues"], spec["max_issues"]], &(is_nil(&1) or (is_integer(&1) and &1 > 0))) and
        (is_nil(spec["route"]) or SymphonyElixir.ModelRouting.validate_route(spec["route"]) == :ok)
    end

    defp valid_channel?(_spec), do: false

    defp validate_channel_ranges(%{valid?: false} = changeset), do: changeset

    defp validate_channel_ranges(changeset) do
      defaults = {get_field(changeset, :min_issues_per_channel), get_field(changeset, :max_issues_per_channel)}

      case Enum.find(get_field(changeset, :channels), &inverted_range?(&1, defaults)) do
        nil -> changeset
        {name, _spec} -> add_error(changeset, :channels, "#{name} min_issues must not exceed max_issues")
      end
    end

    defp inverted_range?({_name, %{} = spec}, {min, max}), do: (spec["min_issues"] || min) > (spec["max_issues"] || max)
    defp inverted_range?(_channel, _defaults), do: false

    defp validate_prompts(field, prompts) do
      if Enum.all?(prompts, fn {kind, path} -> kind in @prompt_kinds and is_binary(path) and String.trim(path) != "" end),
        do: [],
        else: [{field, "keys must be pull_request or research and values must be file paths"}]
    end

    defp validate_fixed_route(field, route) do
      case SymphonyElixir.ModelRouting.validate_route(route) do
        :ok -> []
        {:error, message} -> [{field, message}]
      end
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:autopilot, Autopilot, on_replace: :update, defaults_to_struct: true)
    embeds_one(:throttle, Throttle, on_replace: :update, defaults_to_struct: true)
    embeds_one(:labels, Labels, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pricing, Pricing, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> derive_label_defaults()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          state_name |> to_string() |> String.trim() == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:autopilot, with: &Autopilot.changeset/2)
    |> cast_embed(:throttle, with: &Throttle.changeset/2)
    |> cast_embed(:labels, with: &Labels.changeset/2)
    |> cast_embed(:pricing, with: &Pricing.changeset/2)
    |> validate_fixed_route_floors()
  end

  # Research and review routes run outside the ladder but still honor its
  # `effort_floor`, so a cheap model can never be configured below its floor.
  defp validate_fixed_route_floors(changeset) do
    with %{} = codex <- get_field(changeset, :codex),
         %{} = autopilot <- get_field(changeset, :autopilot),
         {:error, message} <- first_floor_error(codex.routing, fixed_routes(autopilot)) do
      add_error(changeset, :autopilot, message)
    else
      _ -> changeset
    end
  end

  defp fixed_routes(autopilot) do
    channel_routes = for {_name, %{"route" => %{} = route}} <- autopilot.channels, do: route
    [autopilot.research_route, autopilot.review_route | channel_routes]
  end

  defp first_floor_error(routing, routes) do
    Enum.find_value(routes, :ok, fn route ->
      with :ok <- SymphonyElixir.ModelRouting.check_floor(routing, route), do: nil
    end)
  end

  # Labels Symphony reads itself follow `labels.prefix` unless set explicitly:
  # model and size route labels and the blocked label. Only sections that are
  # present are filled; absent ones keep their defaults.
  defp derive_label_defaults(config) do
    prefix =
      case config do
        %{"labels" => %{"prefix" => prefix}} when is_binary(prefix) -> prefix |> String.trim() |> String.downcase()
        _ -> "symphony"
      end

    config
    |> put_new_in(["codex", "routing"], "label_prefix", "#{prefix}:model:")
    |> put_new_in(["codex", "routing"], "size_label_prefix", "#{prefix}:size:")
    |> put_new_in(["autopilot"], "blocked_label", "#{prefix}:blocked")
  end

  defp put_new_in(%{} = config, [], key, value), do: Map.put_new(config, key, value)

  defp put_new_in(%{} = config, [section | rest], key, value) do
    case Map.get(config, section) do
      %{} = inner -> Map.put(config, section, put_new_in(inner, rest, key, value))
      _ -> config
    end
  end

  # Under autopilot a worker ends a failed attempt by adding the blocked label;
  # excluding it stops the item from being redispatched until the orchestrator
  # records the attempt and clears the label.
  defp exclude_blocked_label(tracker, %{enabled: true, blocked_label: label}) when is_binary(label) and label != "",
    do: %{tracker | excluded_labels: Enum.uniq(tracker.excluded_labels ++ [label])}

  defp exclude_blocked_label(tracker, _autopilot), do: tracker

  defp finalize_settings(settings) do
    provider = normalize_optional_map(settings.tracker.provider) || %{}

    {api_key, assignee, provider, secret_environment_names} =
      case settings.tracker.kind do
        "linear" ->
          linear_provider =
            provider
            |> Map.put_new("endpoint", settings.tracker.endpoint || @linear_endpoint)
            |> Map.put_new("api_key", settings.tracker.api_key)
            |> Map.put_new("project_slug", settings.tracker.project_slug)
            |> Map.put_new("assignee", settings.tracker.assignee)

          resolved_api_key =
            resolve_secret_setting(linear_provider["api_key"], System.get_env("LINEAR_API_KEY"))

          resolved_assignee =
            resolve_secret_setting(linear_provider["assignee"], System.get_env("LINEAR_ASSIGNEE"))

          {
            resolved_api_key,
            resolved_assignee,
            linear_provider,
            ["LINEAR_API_KEY" | env_reference_names([linear_provider["api_key"]])]
          }

        _ ->
          {settings.tracker.api_key, settings.tracker.assignee, provider, []}
      end

    {active_states, terminal_states} =
      case settings.tracker.kind do
        kind when kind in ["linear", "memory"] ->
          {
            settings.tracker.active_states || @linear_active_states,
            settings.tracker.terminal_states || @linear_terminal_states
          }

        _ ->
          {settings.tracker.active_states, settings.tracker.terminal_states}
      end

    tracker = %{
      settings.tracker
      | endpoint: Map.get(provider, "endpoint", settings.tracker.endpoint),
        api_key: api_key,
        project_slug: Map.get(provider, "project_slug", settings.tracker.project_slug),
        assignee: assignee,
        provider: provider,
        secret_environment_names: Enum.uniq(secret_environment_names),
        active_states: active_states,
        terminal_states: terminal_states
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    autopilot = %{settings.autopilot | label_prefix: settings.labels.prefix}
    tracker = exclude_blocked_label(tracker, autopilot)

    %{settings | tracker: tracker, workspace: workspace, codex: codex, autopilot: autopilot}
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_secret_setting(value, _fallback), do: value

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp env_reference_names(values) when is_list(values) do
    Enum.flat_map(values, fn value ->
      case env_reference_name(value) do
        {:ok, env_name} -> [env_name]
        :error -> []
      end
    end)
  end

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
