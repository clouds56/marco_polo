defmodule MarcoPolo.ProtocolTest do
  use ExUnit.Case, async: true

  import MarcoPolo.Protocol.BinaryHelpers
  alias MarcoPolo.Protocol

  test "encode_term/1: booleans" do
    assert Protocol.encode_term(true)  == <<1>>
    assert Protocol.encode_term(false) == <<0>>
  end

  test "encode_term/1: nil is serialized as bytes of length -1" do
    assert Protocol.encode_term(nil) == <<-1 :: int>>
  end

  test "encode_term/1: shorts" do
    assert Protocol.encode_term({:short, 34})  == <<34 :: short>>
    assert Protocol.encode_term({:short, -11}) == <<-11 :: short>>
  end

  test "encode_term/1: ints" do
    assert Protocol.encode_term({:int, 2931})   == <<2931 :: int>>
    assert Protocol.encode_term({:int, -85859}) == <<-85859 :: int>>
  end

  test "encode_term/1: longs" do
    assert Protocol.encode_term({:long, 1234567890})  == <<1234567890 :: long>>
    assert Protocol.encode_term({:long, -1234567890}) == <<-1234567890 :: long>>
  end

  test "encode_term/1: Elixir integers are serialized as ints by default" do
    assert Protocol.encode_term(1)   == <<1 :: int>>
    assert Protocol.encode_term(-42) == <<-42 :: int>>
  end

  test "encode_term/1: strings" do
    assert Protocol.encode_term("foo") == <<3 :: int, "foo">>
    assert Protocol.encode_term("føø") == <<byte_size("føø") :: int, "føø">>
  end

  test "encode_term/1: sequences of bytes" do
    assert IO.iodata_to_binary(Protocol.encode_term(<<1, 2, 3>>)) == <<3 :: int, 1, 2, 3>>
  end

  test "encode_term/1: raw bytes" do
    assert IO.iodata_to_binary(Protocol.encode_term({:raw, "foo"})) == "foo"
  end

  test "encode_term/1: iolists" do
    assert IO.iodata_to_binary(Protocol.encode_term([?f, [?o, "o"]])) == <<3 :: int, "foo">>
  end
end
