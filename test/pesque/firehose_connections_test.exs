defmodule Pesque.FirehoseConnectionsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Pesque.FirehoseConnections
  alias PesqueWeb.Plugs.FirehoseConnections, as: Plug

  @settings [
    firehose_connection_rate_limit: 5,
    firehose_ip_connection_limit: 4,
    firehose_global_connection_limit: 64
  ]

  setup do
    previous =
      Enum.map(@settings, fn {key, _default} -> {key, Application.fetch_env(:pesque, key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:pesque, key, value)
        {key, :error} -> Application.delete_env(:pesque, key)
      end)
    end)

    Enum.each(@settings, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    :ok
  end

  test "admits up to the per-IP cap and then up to the global cap" do
    limits(ip: 2, global: 3)

    assert {:ok, _one} = attempt("198.51.100.1")
    assert {:ok, _two} = attempt("198.51.100.1")
    assert {:error, :ip_limit} = attempt("198.51.100.1")
    assert {:ok, _three} = attempt("198.51.100.2")
    assert {:error, :global_limit} = attempt("198.51.100.3")
  end

  test "reads connection caps from runtime configuration" do
    limits(ip: 1, global: 2)

    assert {:ok, _one} = attempt("198.51.100.5")
    assert {:error, :ip_limit} = attempt("198.51.100.5")

    Application.put_env(:pesque, :firehose_ip_connection_limit, 2)

    assert {:ok, _two} = attempt("198.51.100.5")
  end

  test "a DOWN releases both counters and permits connections again" do
    limits(ip: 1, global: 1)

    assert {:ok, first} = attempt("198.51.100.10")
    assert {:error, :ip_limit} = attempt("198.51.100.10")
    assert {:error, :global_limit} = attempt("198.51.100.11")

    kill_owner(first)

    assert {:ok, second} = await_admission("198.51.100.11")
    assert {:error, :global_limit} = attempt("198.51.100.10")

    stop_owner(second)

    assert {:ok, _third} = await_admission("198.51.100.10")
  end

  test "normal per-IP and global refusals do not consume a concurrent slot" do
    limits(ip: 1, global: 2)

    assert {:ok, first} = attempt("198.51.100.20")

    ip_refusal = request("198.51.100.20") |> Plug.call([])
    assert ip_refusal.status == 429
    assert JSON.decode!(ip_refusal.resp_body)["error"] == "FirehoseConnectionLimitExceeded"

    assert {:ok, _second} = attempt("198.51.100.21")

    global_refusal = request("198.51.100.22") |> Plug.call([])
    assert global_refusal.status == 503
    assert JSON.decode!(global_refusal.resp_body)["error"] == "FirehoseUnavailable"

    stop_owner(first)
    assert {:ok, ip_reconnect} = await_admission("198.51.100.20")
    stop_owner(ip_reconnect)

    assert {:ok, _third} = await_admission("198.51.100.22")
  end

  defp attempt(address) do
    parent = self()

    pid =
      spawn(fn ->
        result = FirehoseConnections.admit(address)
        send(parent, {:admission, self(), result})

        if result == :ok do
          receive do
            :close -> :ok
          end
        end
      end)

    assert_receive {:admission, ^pid, result}

    if result == :ok do
      on_exit(fn ->
        terminate_owner(pid)
      end)
    end

    case result do
      :ok -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_admission(address, attempts \\ 100)

  defp await_admission(address, attempts) when attempts > 0 do
    case attempt(address) do
      {:ok, _pid} = result ->
        result

      {:error, _reason} ->
        Process.sleep(1)
        await_admission(address, attempts - 1)
    end
  end

  defp await_admission(_address, 0), do: flunk("firehose connection slot was not released")

  defp stop_owner(pid) do
    total = :sys.get_state(FirehoseConnections).total
    ref = Process.monitor(pid)
    send(pid, :close)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    await_total(total - 1)
  end

  defp kill_owner(pid) do
    total = :sys.get_state(FirehoseConnections).total
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    await_total(total - 1)
  end

  defp terminate_owner(pid) do
    if Process.alive?(pid) do
      total = :sys.get_state(FirehoseConnections).total
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> await_total(total - 1)
      end
    end
  end

  defp await_total(total, attempts \\ 100)

  defp await_total(total, attempts) when attempts > 0 do
    if :sys.get_state(FirehoseConnections).total == total do
      :ok
    else
      Process.sleep(1)
      await_total(total, attempts - 1)
    end
  end

  defp await_total(_total, 0), do: flunk("firehose connection count did not settle")

  defp limits(ip: ip_limit, global: global_limit) do
    Application.put_env(:pesque, :firehose_ip_connection_limit, ip_limit)
    Application.put_env(:pesque, :firehose_global_connection_limit, global_limit)
  end

  defp request(address) do
    conn(:get, "/")
    |> put_req_header("x-forwarded-for", address)
  end
end
