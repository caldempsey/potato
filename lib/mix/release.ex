defmodule Mix.Release do
  defstruct [
    :name,
    :version,
    :root,
    :version_path,
    :erts_path,
    :erts_version,
    :applications,
    :options
  ]

  @type mode :: :permanent | :transient | :temporary | :load | :none
  @type application :: {atom(), charlist(), mode} | {atom(), charlist(), mode, [atom()]}
  @type t :: %{
          name: atom(),
          version: String.t(),
          root: String.t(),
          version_path: String.t(),
          erts_path: charlist() | nil,
          erts_version: charlist(),
          applications: [application],
          options: keyword()
        }

  @default_apps %{iex: :permanent, elixir: :permanent, sasl: :permanent}
  @valid_modes [:permanent, :temporary, :transient, :load, :none]

  @doc false
  def new!(config) do
    {name, apps, opts} = find_release(config)
    apps = Map.merge(@default_apps, apps)

    {include_erts, opts} = Keyword.pop(opts, :include_erts, true)
    {erts_path, erts_version} = erts_data(include_erts)

    rel_apps =
      apps
      |> Map.keys()
      |> traverse_apps(%{}, apps)
      |> Map.values()
      |> Enum.sort()

    root = Path.join([Mix.Project.build_path(config), "rel", Atom.to_string(name)])
    version = opts[:version] || Keyword.fetch!(config, :version)

    %Mix.Release{
      name: name,
      version: version,
      root: root,
      version_path: Path.join([root, "releases", version]),
      erts_path: erts_path,
      erts_version: erts_version,
      applications: rel_apps,
      options: opts
    }
  end

  defp erts_data(false) do
    {nil, :erlang.system_info(:version)}
  end

  defp erts_data(true) do
    version = :erlang.system_info(:version)
    {:filename.join(:code.root_dir(), 'erts-#{version}'), version}
  end

  defp erts_data(erts_path) when is_binary(erts_path) do
    if File.exists?(erts_path) do
      [_, erts_version] = erts_path |> Path.basename() |> String.split("-")
      {to_charlist(erts_path), to_charlist(erts_version)}
    else
      Mix.raise("Could not find ERTS system at #{inspect(erts_path)}")
    end
  end

  defp find_release(config) do
    {name, opts} = lookup_release(config) || infer_release(config)
    {apps, opts} = Keyword.pop(opts, :applications, [])
    apps = Map.new(apps)

    if Mix.Project.umbrella?(config) do
      unless opts[:version] do
        Mix.raise(
          "No version found for release #{inspect(name)}. " <>
            "Releases inside umbrella must have :version set"
        )
      end

      unless apps != %{} do
        Mix.raise(
          "No applications found for release #{inspect(name)}. " <>
            "Releases inside umbrella must have :applications set to a non-empty list"
        )
      end

      {name, apps, opts}
    else
      {name, Map.put_new(apps, Keyword.fetch!(config, :app), :permanent), opts}
    end
  end

  defp lookup_release(_config) do
    # TODO: Implement me
    nil
  end

  defp infer_release(config) do
    if Mix.Project.umbrella?(config) do
      Mix.raise("TODO: we can't infer, raise nice error")
    else
      {Keyword.fetch!(config, :app), []}
    end
  end

  defp traverse_apps(apps, seen, modes) do
    for app <- apps,
        not Map.has_key?(seen, app),
        reduce: seen do
      seen -> traverse_app(app, seen, modes)
    end
  end

  defp traverse_app(app, seen, modes) do
    mode = Map.get(modes, app, :permanent)

    unless mode in @valid_modes do
      Mix.raise(
        "unknown mode #{inspect(mode)} for #{inspect(app)}. " <>
          "Valid modes are: #{inspect(@valid_modes)}"
      )
    end

    case :file.consult(Application.app_dir(app, "ebin/#{app}.app")) do
      {:ok, terms} ->
        [{:application, ^app, properties}] = terms
        seen = Map.put(seen, app, build_app_for_release(app, mode, properties))
        traverse_apps(Keyword.get(properties, :applications, []), seen, modes)

      {:error, reason} ->
        Mix.raise("Could not load #{app}.app. Reason: #{inspect(reason)}")
    end
  end

  defp build_app_for_release(app, mode, properties) do
    vsn = Keyword.fetch!(properties, :vsn)

    case Keyword.get(properties, :included_applications, []) do
      [] -> {app, vsn, mode}
      included_apps -> {app, vsn, mode, included_apps}
    end
  end
end

defmodule Mix.Tasks.Release do
  @moduledoc """

  ## Command line options

    * `--no-archives-check` - does not check archive
    * `--no-deps-check` - does not check dependencies
    * `--no-elixir-version-check` - does not check Elixir version
    * `--no-compile` - does not compile before assembling the release

  """

  # TODO: Copy or evaluate rel/vm.args{.eex} if one is available
  # TODO: Support --force
  # TODO: Docs, docs, docs, docs, docs, docs, docs
  # TODO: Overlays
  # TODO: Relups and appups
  # TODO: Runtime configuration (with Config and ConfigReader)
  # TODO: Support :steps

  use Mix.Task
  import Mix.Generator

  @remote_apps [:kernel, :stdlib, :iex, :elixir, :logger, :compiler]
  @copy_app_dirs ["ebin", "include", "priv"]

  @impl true
  def run(args) do
    # TODO: Parse args
    Mix.Project.get!()
    config = Mix.Project.config()
    Mix.Task.run("loadpaths", args)

    unless "--no-compile" in args do
      Mix.Project.compile(args, config)
    end

    release = Mix.Release.new!(config)

    if not File.exists?(release.version_path) or
         Mix.shell().yes?("Release #{release.name}-#{release.version} already exists. Override?") do
      assemble(release, config)
      announce(release)
    end
  end

  ## assemble

  defp assemble(release, config) do
    # releases/
    #   VERSION/
    #     consolidated/
    #     NAME.rel
    #     remote.boot
    #     remote.script
    #     start.boot
    #     start.script
    #     sys.config
    build_rel(release, config)

    # lib/
    #   APP_NAME-APP_VSN/
    #     ebin/
    #     priv/
    build_lib(release)

    # bin/
    #   RELEASE_NAME
    #   RELEASE_NAME.data
    # releases/
    #   VERSION/
    #     elixir
    #     elixir.bat
    #     iex
    #     iex.bat
    copy_executables(release)

    # erts-ERTS_VSN/
    copy_erts(release)

    # releases/
    #   COOKIE
    #   start_erl.data
    write_data(release)
  end

  defp build_rel(release, config) do
    File.rm_rf!(release.version_path)
    File.mkdir_p!(release.version_path)
    variables = build_variables()

    with :ok <- build_sys_config(release, config),
         :ok <- build_vm_args(release),
         :ok <- build_release_rel(release, variables),
         :ok <- build_remote_rel(release, variables) do
      if copy_consolidated(config, release) do
        rewrite_rel_script_with_consolidated(release)
      else
        rename_rel_script(release)
      end
    else
      {:error, message} ->
        File.rm_rf!(release.version_path)
        Mix.raise(message)
    end
  end

  defp build_variables do
    erts_dir = :code.lib_dir()

    for path <- :code.get_path(),
        path != '.',
        not List.starts_with?(path, erts_dir),
        uniq: true,
        do: {'RELEASE_LIB', path |> :filename.dirname() |> :filename.dirname()}
  end

  defp build_vm_args(release) do
    File.write!(Path.join(release.version_path, "vm.args"), vm_args_text())
    :ok
  end

  defp build_sys_config(release, config) do
    contents =
      if File.regular?(config[:config_path]) do
        config[:config_path] |> Mix.Config.eval!() |> elem(0)
      else
        []
      end

    sys_config = Path.join(release.version_path, "sys.config")
    File.write!(sys_config, consultable("config", contents))

    case :file.consult(sys_config) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, "Could not write configuration file. Reason: #{inspect(reason)}"}
    end
  end

  defp build_release_rel(release, variables) do
    rel_path = Path.join(release.version_path, "#{release.name}.rel")
    build_rel_boot_and_script(rel_path, release, release.applications, variables)
  end

  defp build_remote_rel(release, variables) do
    remote_apps = for app <- release.applications, elem(app, 0) in @remote_apps, do: app
    rel_path = Path.join(release.version_path, "remote.rel")
    result = build_rel_boot_and_script(rel_path, release, remote_apps, variables)
    File.rm(rel_path)
    result
  end

  defp build_rel_boot_and_script(rel_path, release, apps, variables) do
    %{name: name, version: version, erts_version: erts_version} = release
    rel_spec = {:release, {to_charlist(name), to_charlist(version)}, {:erts, erts_version}, apps}
    File.write!(rel_path, consultable("rel", rel_spec))

    sys_path = rel_path |> Path.rootname() |> to_charlist()
    sys_options = [:silent, :no_dot_erlang, :no_warn_sasl, variables: variables]

    case :systools.make_script(sys_path, sys_options) do
      {:ok, _module, _warnings} ->
        :ok

      {:error, module, info} ->
        {:error, module.format_error(info) |> to_string() |> String.trim()}
    end
  end

  defp copy_consolidated(config, release) do
    if config[:consolidate_protocols] do
      source = Mix.Project.consolidation_path(config)
      target = Path.join(release.version_path, "consolidated")
      File.cp_r!(source, target)
      target
    end
  end

  defp rewrite_rel_script_with_consolidated(release) do
    consolidated = '$RELEASE_LIB/../releases/#{release.version}/consolidated'

    {:ok, [{:script, rel_info, instructions}]} =
      :file.consult(Path.join(release.version_path, "#{release.name}.script"))

    new_instructions =
      Enum.map(instructions, fn
        {:path, paths} ->
          if Enum.any?(paths, &List.starts_with?(&1, '$RELEASE_LIB')) do
            {:path, [consolidated | paths]}
          else
            {:path, paths}
          end

        other ->
          other
      end)

    script = {:script, rel_info, new_instructions}
    File.write!(Path.join(release.version_path, "start.script"), consultable("script", script))
    :ok = :systools.script2boot(to_charlist(Path.join(release.version_path, "start")))
  after
    File.rm(Path.join(release.version_path, "#{release.name}.script"))
    File.rm(Path.join(release.version_path, "#{release.name}.boot"))
  end

  defp rename_rel_script(release) do
    for ext <- [:boot, :script] do
      File.rename(
        Path.join(release.version_path, "#{release.name}.#{ext}"),
        Path.join(release.version_path, "start.#{ext}")
      )
    end

    :ok
  end

  defp consultable(kind, term) do
    {date, time} = :erlang.localtime()
    args = [kind, date, time, term]
    :io_lib.format("%% coding: utf-8~n%% ~ts generated at ~p ~p~n~p.~n", args)
  end

  defp build_lib(release) do
    release.applications
    |> Task.async_stream(&copy_app(&1, release), ordered: false, timeout: :infinity)
    |> Stream.run()
  end

  defp copy_app(app_spec, release) do
    # TODO: Do not copy ERTS apps if include ERTS is false
    # TODO: Strip beams

    app = elem(app_spec, 0)
    vsn = elem(app_spec, 1)
    source_app = Application.app_dir(app)
    target_app = Path.join([release.root, "lib", "#{app}-#{vsn}"])

    File.rm_rf!(target_app)
    File.mkdir_p!(target_app)

    for dir <- @copy_app_dirs do
      source_dir = Path.join(source_app, dir)
      target_dir = Path.join(target_app, dir)
      File.exists?(source_dir) && File.cp_r!(source_dir, target_dir)
    end

    target_app
  end

  defp copy_executables(release) do
    elixir_bin_path = Application.app_dir(:elixir, "../../bin")
    bin_path = Path.join(release.root, "bin")
    File.mkdir_p!(bin_path)

    for os <- Keyword.get(release.options, :include_executables_for, [:unix, :windows]) do
      [{start, contents} | clis] = cli_for(os, release)
      start_path = Path.join(bin_path, start)

      unless File.exists?(start_path) do
        File.write!(start_path, contents)
        executable!(start_path)
      end

      for {filename, contents} <- clis do
        path = Path.join(bin_path, filename)
        File.write!(path, contents)
        executable!(path)
      end

      unless File.exists?(elixir_bin_path) do
        Mix.raise("Could not find bin files from Elixir installation")
      end

      for {filename, contents} <- elixir_cli_for(os, elixir_bin_path, release) do
        path = Path.join(release.version_path, filename)
        File.write!(path, contents)
        executable!(path)
      end
    end
  end

  # TODO: Implement windows CLI
  defp cli_for(_os, release) do
    [
      {"start", start_template(name: release.name)},
      {"#{release.name}", cli_template(name: release.name)}
    ]
  end

  defp elixir_cli_for(:unix, bin_path, release) do
    [
      {"elixir",
       Path.join(bin_path, "elixir")
       |> File.read!()
       |> String.replace(~s[ -pa "$SCRIPT_PATH"/../lib/*/ebin], "")
       |> replace_erts_bin(release, ~s["$SCRIPT_PATH"/../../erts-#{release.erts_version}/bin/])},
      {"iex", File.read!(Path.join(bin_path, "iex"))}
    ]
  end

  defp elixir_cli_for(:windows, bin_path, release) do
    [
      {"elixir.bat",
       Path.join(bin_path, "elixir.bat")
       |> File.read!()
       |> String.replace(~s[goto expand_erl_libs], ~s[goto run])
       |> replace_erts_bin(release, ~s["%dp0\\..\\..\\erts-#{release.erts_version}\\bin\\"])},
      {"iex.bat", File.read!(Path.join(bin_path, "iex"))}
    ]
  end

  defp executable!(path), do: File.chmod!(path, 0o744)

  defp replace_erts_bin(contents, release, new_path) do
    if release.erts_path do
      String.replace(contents, ~s[ERTS_BIN=""], ~s[ERTS_BIN=#{new_path}])
    else
      contents
    end
  end

  defp copy_erts(release) do
    if release.erts_path do
      File.cp_r!(release.erts_path, Path.join(release.root, "erts-#{release.erts_version}"))
    end

    :ok
  end

  defp write_data(release) do
    cookie_path = Path.join(release.root, "releases/COOKIE")

    # TODO: If there is a cookie option and the cookie option
    # is not the same as the file, ask to override.
    unless File.exists?(cookie_path) do
      File.write!(cookie_path, random_cookie())
    end

    start_erl_path = Path.join(release.root, "releases/start_erl.data")
    File.write!(start_erl_path, "#{release.erts_version} #{release.version}")
    :ok
  end

  defp random_cookie, do: Base.url_encode64(:crypto.strong_rand_bytes(40))

  defp announce(release) do
    path = Path.relative_to_cwd(release.root)
    cmd = "#{path}/bin/#{release.name}"
    Mix.shell().info([:green, "Release created at #{path}!"])

    Mix.shell().info("""

        # To start your system
        #{path}/bin/start

    See the start script for more information. Once the release is running:

        # To connect to it remotely
        #{cmd} remote

        # To stop it gracefully (you may also use SIGINT/SIGTERM)
        #{cmd} stop

        # To execute Elixir code remotely
        #{cmd} rpc EXPR
    """)
  end

  ## Templates

  embed_text(:vm_args, """
  ## Do not load code from filesystem as all modules are preloaded
  -mode embedded

  ## Disable the heartbeat system to automatically restart the VM
  ## if it dies or becomes unresponsive. Useful only in daemon mode.
  ##-heart

  ## Number of diry schedulers doing IO work (file, sockets, etc)
  ##+SDio 5

  ## Increase number of concurrent ports/sockets
  ##-env ERL_MAX_PORTS 4096

  ## Tweak GC to run more often
  ##-env ERL_FULLSWEEP_AFTER 10
  """)

  embed_template(:start, """
  #!/bin/sh
  set -e
  # Feel free to edit this file in anyway you want
  # To start your system using IEx: . $(dirname "$0")/<%= @name %> start iex
  # To start it as a daemon using IEx: . $(dirname "$0")/<%= @name %> daemon iex
  . $(dirname "$0")/<%= @name %> start
  """)

  # TODO: improve help
  embed_template(:cli, """
  #!/bin/sh
  set -e

  SELF=$(readlink "$0" || true)
  if [ -z "$SELF" ]; then SELF="$0"; fi
  export RELEASE_ROOT="$(cd "$(dirname "$SELF")/.." && pwd -P)"
  export RELEASE_NAME="${RELEASE_NAME:-"<%= @name %>"}"
  export RELEASE_VSN="${RELEASE_VSN:-"$(cut -d' ' -f2 "$RELEASE_ROOT/releases/start_erl.data")"}"
  export COOKIE=${COOKIE:-$(cat "$RELEASE_ROOT/releases/COOKIE")}
  REL_VSN_DIR="$RELEASE_ROOT/releases/$RELEASE_VSN"

  gen_id () {
    od -t x -N 4 /dev/urandom | head -n1 | awk '{print $2}'
  }

  rpc () {
    exec "$REL_VSN_DIR/elixir" \\
         --hidden --name "rpc-$(gen_id)@127.0.0.1" --cookie "$COOKIE" \\
         --erl-config "${REL_VSN_DIR}/sys" \\
         --boot "${REL_VSN_DIR}/remote" \\
         --boot-var RELEASE_LIB "$RELEASE_ROOT/lib" \\
         --rpc-eval "$RELEASE_NAME@127.0.0.1" "$1"
  }

  start () {
    exec "$REL_VSN_DIR/$1" --no-halt \\
         --werl --name "$RELEASE_NAME@127.0.0.1" --cookie "$COOKIE" \\
         --erl-config "${REL_VSN_DIR}/sys" \\
         --boot "${REL_VSN_DIR}/start" \\
         --boot-var RELEASE_LIB "$RELEASE_ROOT/lib" \\
         --vm-args "${REL_VSN_DIR}/vm.args" "${@:2}"
  }

  case $1 in
    start)
      start ${2:-elixir}
      ;;

    daemon)
      export RELEASE_TMP="${RELEASE_TMP:-"$RELEASE_ROOT/tmp"}"
      start ${2:-elixir} --pipe-to "${RELEASE_TMP}/pipe" "${RELEASE_TMP}/log"
      ;;

    remote)
      exec "$REL_VSN_DIR/iex" \\
           --werl --hidden --name "remote-$(gen_id)@127.0.0.1" --cookie "$COOKIE" \\
           --erl-config "${REL_VSN_DIR}/sys" \\
           --boot "${REL_VSN_DIR}/remote" \\
           --boot-var RELEASE_LIB "$RELEASE_ROOT/lib" \\
           --remsh "$RELEASE_NAME@127.0.0.1"
      ;;

    rpc)
      if [ -z "$2" ]; then
        echo "BAD RPC" >&2
        exit 1
      fi
      rpc "$2"
      ;;

    restart|stop)
      rpc "System.$1"
      ;;

    pid)
      rpc "IO.puts System.pid"
      ;;

    *)
      echo "BAD COMMAND" >&2
      exit 1
      ;;
  esac
  """)
end
