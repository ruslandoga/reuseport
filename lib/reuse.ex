defmodule Reuse do
  @moduledoc File.read!("README.md")
  use GenServer

  @type option ::
          {:port, :inet.port_number()}
          | {:callback, (iodata() -> iodata())}
          | GenServer.option()

  @spec server([option]) :: GenServer.on_start()
  def server(opts \\ []) do
    {gen_opts, opts} = Keyword.split(opts, [:debug, :name, :spawn_opt, :hibernate_after])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec drain(pid | GenServer.name()) :: :ok
  def drain(server), do: GenServer.call(server, :drain)

  @spec socket(pid | GenServer.name()) :: :gen_tcp.socket() | nil
  def socket(server), do: GenServer.call(server, :socket)

  @spec acceptors(pid | GenServer.name()) :: :ets.table()
  def acceptors(server), do: GenServer.call(server, :acceptors)

  @spec stop(pid | GenServer.name()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 0)
    callback = Keyword.get(opts, :callback, &Function.identity/1)

    {:ok, socket} =
      :gen_tcp.listen(port,
        mode: :binary,
        packet: :raw,
        active: false,
        reuseport: true,
        reuseport_lb: true,
        reuseaddr: true
      )

    acceptors = :ets.new(:acceptors, [:protected, :set, read_concurrency: true])
    state = {socket, acceptors, callback}
    for _ <- 1..10, do: spawn_acceptor(state)

    {:ok, state}
  end

  @impl true
  def handle_call(:drain, _from, {socket, acceptors, callback}) do
    :ok = :gen_tcp.close(socket)
    {:reply, :ok, {nil, acceptors, callback}}
  end

  def handle_call(:acceptors, _from, {_socket, acceptors, _callback} = state) do
    {:reply, acceptors, state}
  end

  def handle_call(:socket, _from, {socket, _acceptors, _callback} = state) do
    {:reply, socket, state}
  end

  @impl true
  def handle_cast(:accepted, {socket, _acceptors, _callback} = state) do
    if socket, do: spawn_acceptor(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case reason do
      :normal ->
        remove_acceptor(state, pid)
        {:noreply, state}

      :emfile ->
        raise "no more file descriptors"

      reason ->
        :telemetry.execute([:reuse, :acceptor, :crash], reason)
        {:noreply, state}
    end
  end

  defp remove_acceptor({_socket, acceptors, _callback}, pid) do
    :ets.delete(acceptors, pid)
  end

  defp spawn_acceptor({socket, acceptors, callback}) do
    {pid, _ref} =
      :proc_lib.spawn_opt(
        __MODULE__,
        :accept,
        [_parent = self(), socket, callback],
        [:monitor, fullsweep_after: 0]
      )

    :ets.insert(acceptors, {pid})
  end

  @doc false
  def accept(parent, socket, callback) do
    case :gen_tcp.accept(socket, :timer.seconds(10)) do
      {:ok, socket} ->
        GenServer.cast(parent, :accepted)
        callback_loop(socket, callback)

      {:error, :timeout} ->
        accept(parent, socket, callback)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit(reason)
    end
  end

  defp callback_loop(socket, callback) do
    case :gen_tcp.recv(socket, 0, :infinity) do
      {:ok, data} ->
        :gen_tcp.send(socket, callback.(data))
        callback_loop(socket, callback)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit(reason)
    end
  end
end
