defmodule ReuseTest do
  use ExUnit.Case

  test "it works" do
    # start v1
    {:ok, server_v1} = Reuse.server(port: 8000, callback: fn data -> "v1:" <> data end)

    # connect to v1
    client_1 = connect(8000)
    assert "v1:hello" == request(client_1, "hello")

    # start v2
    {:ok, _server_v2} = Reuse.server(port: 8000, callback: fn data -> "v2:" <> data end)

    # drain v1 (close listen socket, stop awaiting acceptors)
    :ok = Reuse.drain(server_v1)

    # first client still active, still connected to v1
    assert "v1:alive" == request(client_1, "alive")

    # new clients go to v2
    client_2 = connect(8000)
    assert "v2:hello" == request(client_2, "hello")

    # closing v1 clients removes acceptors
    close(client_1)

    # stop v1 once there are no more clients
    wait_for_zero_acceptors(Reuse.acceptors(server_v1), _within = :timer.seconds(5))
    :ok = Reuse.stop(server_v1)

    # v2 still works
    assert "v2:hello" == request(client_2, "hello")
  end

  defp connect(port) do
    assert {:ok, socket} = :gen_tcp.connect(~c"localhost", port, active: false, mode: :binary)
    socket
  end

  defp request(socket, data) do
    assert :ok == :gen_tcp.send(socket, data)
    assert {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
    response
  end

  defp close(socket) do
    assert :ok == :gen_tcp.close(socket)
  end

  defp wait_for_zero_acceptors(acceptors, timeout) do
    test = self()
    spawn_link(fn -> loop_if_has_acceptors(test, acceptors) end)
    assert_receive :zero_acceptors, timeout
  end

  defp loop_if_has_acceptors(test, acceptors) do
    :timer.sleep(100)

    case :ets.info(acceptors, :size) do
      0 -> send(test, :zero_acceptors)
      _n -> loop_if_has_acceptors(test, acceptors)
    end
  end
end
