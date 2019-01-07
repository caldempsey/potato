defmodule Potato.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      {Task, fn -> Stream.interval(1000) |> Stream.each(&IO.puts/1) |> Stream.run() end}
    ]

    opts = [strategy: :one_for_one, name: Potato.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
