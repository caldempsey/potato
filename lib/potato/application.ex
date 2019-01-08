defmodule Potato.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    interval = Application.get_env(:potato, :interval)
    fun = fn -> Stream.interval(interval) |> Stream.each(&IO.puts/1) |> Stream.run() end

    children = [
      Supervisor.child_spec({Task, fun}, restart: :permanent),
    ]

    opts = [strategy: :one_for_one, name: Potato.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
