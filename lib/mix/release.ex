defmodule Mix.Release do
  defstruct [
    :name,
    :version,
    :path,
    :erts_path,
    :erts_version,
    :applications,
    :options
  ]

  @type mode :: :permanent | :transient | :temporary | :load | :none
  @type application :: {atom(), charlist(), mode} | {atom(), charlist(), mode, [atom()]}
  @type t :: %{
          name: atom(),
          version: charlist(),
          path: String.t(),
          erts_path: charlist() | nil,
          erts_version: charlist(),
          applications: [application],
          options: keyword()
        }
end

defmodule Mix.Tasks.Release do
  @moduledoc """

  ## Command line options

    * `--no-archives-check` - does not check archive
    * `--no-deps-check` - does not check dependencies
    * `--no-elixir-version-check` - does not check Elixir version
    * `--no-compile` - does not compile before assembling the release

  """

  # TODO: Docs, docs, docs, docs, docs, docs, docs
  # TODO: Overlays
  # TODO: Protocol consolidation
  # TODO: Relups and appups
  # TODO: Configuration

  use Mix.Task
  import Mix.Generator

  @default_apps %{iex: :permanent, elixir: :permanent, sasl: :permanent}
  @remsh_apps [:kernel, :stdlib, :iex, :elixir, :logger, :compiler]
  @valid_modes [:permanent, :temporary, :transient, :load, :none]

  @impl true
  def run(args) do
    # TODO: Parse args
    Mix.Project.get!()
    config = Mix.Project.config()
    Mix.Task.run("loadpaths", args)

    unless "--no-compile" in args do
      Mix.Project.compile(args, config)
    end

    config
    |> build_release()
    |> assemble()
  end

  ## build_release

  defp build_release(config) do
    {name, apps, opts} = find_release(config)
    {include_erts, opts} = Keyword.pop(opts, :include_erts, true)
    {erts_path, erts_version} = erts_data(include_erts)

    rel_apps =
      apps
      |> Map.keys()
      |> traverse_apps(%{}, apps)
      |> Map.values()
      |> Enum.sort()

    %Mix.Release{
      name: name,
      version: config |> Keyword.fetch!(:version) |> to_charlist(),
      path: Path.join([Mix.Project.build_path(config), "rel", Atom.to_string(name)]),
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

    default_apps =
      if Mix.Project.umbrella?(config) do
        @default_apps
      else
        Map.put(@default_apps, Keyword.fetch!(config, :app), :permanent)
      end

    {name, Map.merge(default_apps, Map.new(apps)), opts}
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

  ## assemble

  defp assemble(release) do
    release_version_path = Path.join([release.path, "releases", release.version])

    if not File.exists?(release_version_path) or
         Mix.shell().yes?("Release #{release.name}-#{release.version} already exists. Override?") do
      # releases/
      #   VERSION/
      #     NAME.rel
      #     remsh.boot
      #     remsh.script
      #     start.boot
      #     start.script
      build_rel(release, release_version_path)

      # lib/
      #   APP_NAME-APP_VSN/
      #     ebin/
      #     priv/
      build_lib(release)

      # bin/
      #   REL_NAME
      #   REL_NAME.data
      # releases/
      #   VERSION/
      #     elixir
      #     elixir.bat
      #     iex
      #     iex.bat
      copy_executables(release, release_version_path)

      # erts-ERTS_VSN/
      copy_erts(release)

      # releases/
      #   COOKIE
      #   start_erl.data
      write_data(release)

      announce(release)
    end
  end

  defp build_rel(release, release_version_path) do
    File.rm_rf!(release_version_path)
    File.mkdir_p!(release_version_path)
    File.write!(Path.join(release_version_path, "vm.args"), vm_args_text())

    variables = build_variables()
    rel_path = Path.join(release_version_path, "#{release.name}.rel")
    build_rel_boot_and_script(rel_path, release, release.applications, variables)

    for ext <- [:boot, :script] do
      File.rename(
        Path.join(release_version_path, "#{release.name}.#{ext}"),
        Path.join(release_version_path, "start.#{ext}")
      )
    end

    remsh_apps = for app <- release.applications, elem(app, 0) in @remsh_apps, do: app
    rel_path = Path.join(release_version_path, "remsh.rel")
    build_rel_boot_and_script(rel_path, release, remsh_apps, variables)
    File.rm(rel_path)
  end

  defp build_variables do
    erts_dir = :code.lib_dir()

    for path <- :code.get_path(),
        path != '.',
        not List.starts_with?(path, erts_dir),
        uniq: true,
        do: {'RELEASE_LIB', path |> :filename.dirname() |> :filename.dirname()}
  end

  defp build_rel_boot_and_script(rel_path, release, apps, variables) do
    %{name: name, version: version, erts_version: erts_version} = release
    rel_spec = {:release, {to_charlist(name), version}, {:erts, erts_version}, apps}
    File.write!(rel_path, :io_lib.format("%% coding: utf-8~n~p.~n", [rel_spec]))

    sys_path = rel_path |> Path.rootname() |> to_charlist()
    sys_options = [:silent, :no_dot_erlang, :no_warn_sasl, variables: variables]

    case :systools.make_script(sys_path, sys_options) do
      {:error, module, info} ->
        File.rm_rf(Path.dirname(sys_path))
        Mix.raise(module.format_error(info) |> to_string() |> String.trim())

      {:ok, _module, _warnings} ->
        :ok
    end
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
    source_ebin = Path.join(source_app, "ebin")
    source_priv = Path.join(source_ebin, "priv")

    app_dir = "#{app}-#{vsn}"
    target_app = Path.join([release.path, "lib", app_dir])
    target_ebin = Path.join(target_app, "ebin")
    target_priv = Path.join(target_app, "priv")

    File.rm_rf!(target_app)
    File.mkdir_p!(target_ebin)
    File.cp_r!(source_ebin, target_ebin)
    File.exists?(source_priv) && File.cp_r!(source_priv, target_priv)

    target_app
  end

  defp copy_executables(release, release_version_path) do
    bin_path = Path.join(release.path, "bin")
    File.mkdir_p!(bin_path)

    for os <- Keyword.get(release.options, :include_executables_for, [:unix, :windows]) do
      {cli, contents} = cli_for(os, release)
      cli_path = Path.join(bin_path, cli)

      unless File.exists?(cli_path) do
        File.write!(cli_path, contents)
        executable!(cli_path)
      end

      elixir_bin_path = Application.app_dir(:elixir, "../../bin")

      unless File.exists?(elixir_bin_path) do
        Mix.raise("Could not find bin files from Elixir installation")
      end

      for {filename, contents} <- elixir_cli_for(os, elixir_bin_path, release) do
        path = Path.join(release_version_path, filename)
        File.write!(path, contents)
        executable!(path)
      end
    end
  end

  # TODO: Implement windows CLI
  defp cli_for(:unix, release), do: {"#{release.name}", cli_template(name: release.name)}
  defp cli_for(:windows, release), do: {"#{release.name}", cli_template(name: release.name)}

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
      File.cp_r!(release.erts_path, Path.join(release.path, "erts-#{release.erts_version}"))
    end

    :ok
  end

  defp write_data(release) do
    cookie_path = Path.join(release.path, "releases/COOKIE")

    # TODO: If there is a cookie option and the cookie option
    # is not the same as the file, ask to override.
    unless File.exists?(cookie_path) do
      File.write!(cookie_path, random_cookie())
    end

    start_erl_path = Path.join(release.path, "releases/start_erl.data")
    File.write!(start_erl_path, "#{release.erts_version} #{release.version}")
    :ok
  end

  defp random_cookie, do: Base.encode64(:crypto.strong_rand_bytes(40))

  defp announce(release) do
    path = Path.relative_to_cwd(release.path)
    cmd = "#{path}/bin/#{release.name}"
    Mix.shell().info([:green, "Release created at #{path}!"])

    Mix.shell().info("""

        # To start your system
        #{cmd} start

        # To start your system using IEx
        #{cmd} start iex

        # To start it as a daemon
        #{cmd} daemon [iex]

    Once the release is running:

        # To connect to it remotely
        #{cmd} remote

        # To stop it gracefully
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

  # TODO: improve help
  embed_template(:cli, """
  #!/bin/sh
  set -e

  SELF=$(readlink "$0" || true)
  if [ -z "$SELF" ]; then SELF="$0"; fi
  REL_ROOT="$(cd "$(dirname "$SELF")/.." && pwd -P)"
  REL_NAME="<%= @name %>"
  REL_VSN="$(cut -d' ' -f2 "$REL_ROOT/releases/start_erl.data")"
  export RELEASE_DIR="${RELEASE_DIR:-"$REL_ROOT/releases/$REL_VSN"}"
  export COOKIE=${COOKIE:-$(cat "$REL_ROOT/releases/COOKIE")}

  gen_id () {
    od -t x -N 4 /dev/urandom | head -n1 | awk '{print $2}'
  }

  rpc () {
    exec "$RELEASE_DIR/elixir" \
         --hidden --name "rpc-$(gen_id)@127.0.0.1" --cookie "$COOKIE" \
         --boot "${RELEASE_DIR}/remsh" \
         --boot-var RELEASE_LIB "$REL_ROOT/lib" \
         --rpc-eval "$REL_NAME@127.0.0.1" "$1"
  }

  start () {
    exec "$RELEASE_DIR/$1" --no-halt \
         --werl --name "$REL_NAME@127.0.0.1" --cookie "$COOKIE" \
         --boot "${RELEASE_DIR}/start" \
         --boot-var RELEASE_LIB "$REL_ROOT/lib" \
         --vm-args "${RELEASE_DIR}/vm.args" "${@:2}"
  }

  case $1 in
    start)
      start ${2:-elixir}
      ;;

    daemon)
      export RELEASE_TMP="${RELEASE_TMP:-"$REL_ROOT/tmp"}"
      start ${2:-elixir} --pipe-to "${RELEASE_TMP}/pipe" "${RELEASE_TMP}/log"
      ;;

    remote)
      exec "$RELEASE_DIR/iex" \
           --werl --hidden --name "remsh-$(gen_id)@127.0.0.1" --cookie "$COOKIE" \
           --boot "${RELEASE_DIR}/remsh" \
           --boot-var RELEASE_LIB "$REL_ROOT/lib" \
           --remsh "$REL_NAME@127.0.0.1"
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
