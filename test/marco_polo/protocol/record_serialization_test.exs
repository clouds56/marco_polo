defmodule MarcoPolo.Protocol.RecordSerializationTest do
  use ExUnit.Case, async: true

  alias MarcoPolo.RID
  alias MarcoPolo.Document
  alias MarcoPolo.DateTime
  alias MarcoPolo.Protocol.RecordSerialization, as: Ser

  import Ser, only: [encode_value: 1, decode_type: 2]

  @record_no_fields <<0,           # version
                      10, "Klass", # class name
                      0,           # end of (empty) header
                      >>

  @record_no_fields_null_class <<0, # version
                                 0, # -1 with zigzag
                                 0, # end of (empty) header
                                 >>

  @record_with_fields <<0,            # version
                        6, "foo",     # class name
                        10, "hello",  # field name
                        0, 0, 0, 25,  # pointer to data
                        7,            # field type (string)
                        6, "int",     # field name
                        0, 0, 0, 32,  # pointer to data
                        1,            # field type (int)
                        0,            # end of header
                        12, "world!", # field value
                        24,           # field value (int with zigzag)
                        >>

  @record_with_property <<0,
                          6, "foo",
                          1, # -1 with zigzag, it's the prop id (0 as a prop id)
                          0, 0, 0, 25,
                          0,
                          10, "value",
                          >>

  @list <<4,            # number of items (zigzag, hence 2)
          23,           # type of the elems in the list, OrientDB only supports ANY
          7, 8, "elem", # elem type (string) + value
          0, 1,         # elem type (boolean) + value
          "foo">>

  # Throughout these tests, remember that ints are encoded as ZigZag and then as
  # varints (often they're just the double of what they should be because of
  # ZigZag).

  ## Decoding

  test "decode/2: record with no fields" do
    assert Ser.decode(@record_no_fields) ==
           %Document{class: "Klass", fields: %{}}
  end

  test "decode/2: record with no fields and null class" do
    assert Ser.decode(@record_no_fields_null_class) ==
           %Document{class: nil}
  end

  test "decode/2: record with fields" do
    record = %Document{class: "foo", fields: %{"hello" => "world!", "int" => 12}}
    assert Ser.decode(@record_with_fields) == record
  end

  test "decode/2: record with properties" do
    record = %Document{class: "foo", fields: %{"prop" => "value"}}
    schema = %{global_properties: %{0 => {"prop", "STRING"}}}
    assert Ser.decode(@record_with_property, schema) == record
  end

  test "decode_type/2: simple types" do
    # booleans
    assert decode_type(<<0, "foo">>, :boolean) == {false, "foo"}
    assert decode_type(<<1, "foo">>, :boolean) == {true, "foo"}

    # integers (with zigzag + varint)
    assert decode_type(<<6, "foo">>, :short) == {3, "foo"}
    assert decode_type(<<44, "foo">>, :int)  == {22, "foo"}
    assert decode_type(<<1, "foo">>, :long)  == {-1, "foo"}

    # floats
    assert {float, "foo"} = decode_type(<<64, 72, 245, 195, "foo">>, :float)
    assert Float.round(float, 2) == 3.14

    # doubles
    assert {float, "foo"} = decode_type(<<64, 9, 30, 184, 81, 235, 133, 31, "foo">>, :double)
    assert Float.round(float, 2) == 3.14

    # strings
    assert decode_type(<<6, "foo", "bar">>, :string) == {"foo", "bar"}

    # binary
    assert decode_type(<<4, 77, 45, "foo">>, :binary) == {<<77, 45>>, "foo"}
  end

  test "decode_type/2: datetime" do
    data = :small_ints.encode_zigzag_varint(1435665809901) <> "foo"
    datetime = %DateTime{year: 2015, month: 6, day: 30,
                         hour: 12, min: 03, sec: 29, msec: 901}
    assert decode_type(data, :datetime) == {datetime, "foo"}
  end

  test "decode_type/2: embedded documents" do
    # Embedded documents have no serialization version
    <<_version, record :: bytes>> = @record_with_fields

    assert decode_type(record <> "rest", :embedded) ==
           {%Document{class: "foo", fields: %{"hello" => "world!", "int" => 12}}, "rest"}
  end

  test "decode_type/2: embedded lists" do
    assert decode_type(@list, :embedded_list) == {["elem", true], "foo"}
  end

  test "decode_type/2: embedded sets" do
    expected_set = Enum.into(["elem", true], HashSet.new)
    assert decode_type(@list, :embedded_set) == {expected_set, "foo"}
  end

  test "decode_type/2: embedded maps" do
    data = <<4,           # number of keys (zigzag, hence 2)
             7,           # key type (string)
             8, "key1",   # key
             0, 0, 0, 14, # ptr to data
             7,           # data type (string)
             7,           # key type (string)
             8, "key2",   # key
             0, 0, 0, 0,  # ptr to data, 0 means null data
             0,           # when ptr is null type is always 0 (which is boolean, but irrelevant)
             10, "value", # key1 value
             "foo">>

    map = %{"key1" => "value", "key2" => nil}
    assert decode_type(data, :embedded_map) == {map, "foo"}
  end

  test "decode_type/2: links" do
    rid = %RID{cluster_id: 17, position: 0}
    assert decode_type(<<34, 0, "foo">>, :link) == {rid, "foo"}
  end

  test "decode_type/2: link lists" do
    data = <<4, # number of elements as a zigzag varint
             2, 4, # link
             16, 18, # link
             "foo">>

    list = {:link_list, [%RID{cluster_id: 1, position: 2}, %RID{cluster_id: 8, position: 9}]}
    assert decode_type(data, :link_list) == {list, "foo"}
  end

  test "decode_type/2: link sets" do
    data = <<4, # number of elements as a zigzag varint
             18, 18, # link
             0, 2, # link
             "foo">>

    links        = [%RID{cluster_id: 9, position: 9}, %RID{cluster_id: 0, position: 1}]
    expected_set = Enum.into(links, HashSet.new)
    assert {{:link_set, set}, "foo"} = Ser.decode_type(data, :link_set)
    assert Set.equal?(expected_set, set)
  end

  test "decode_type/2: link maps" do
    expected_map = %{
      "foo" => %RID{cluster_id: 1, position: 2},
      "bar" => %RID{cluster_id: 3, position: 9},
    }

    data = <<4, # nkeys, varint
             7, 6, "foo", # key type + key value
             <<2, 4>>, # rid
             7, 6, "bar", # key type + key value
             <<6, 18>>, # rid
             "foo">>

    assert decode_type(data, :link_map) == {{:link_map, expected_map}, "foo"}
  end

  test "decode_type/2: decimals" do
    Decimal.set_context(%Decimal.Context{precision: 5})

    data = <<0, 0, 0, 4,   # scale as...4 bytes? why? :(
             0, 0, 0, 2,   # length of the value bytes as...4 bytes :(
             <<122, 183>>, # value (31415)
             "foo">>

    assert decode_type(data, :decimal) == {Decimal.new(3.1415), "foo"}
  end

  test "decode_type/2: link bags (embedded)" do
    data = <<1,                 # embedded link bag
             2 :: 32,           # size
             1 :: 16, 22 :: 64, # rid
             9 :: 16, 14 :: 64, # rid
             "foo">>

    rids = [%RID{cluster_id: 1, position: 22}, %RID{cluster_id: 9, position: 14}]
    assert decode_type(data, :link_bag) == {{:link_bag, rids}, "foo"}
  end

  test "decode_type/2: link bags (tree)" do
    # Whatever binary fails as long as the first byte is not 1 (which is
    # embedded linkbag).
    exception = assert_raise MarcoPolo.Error, fn ->
      decode_type(<<0, 1, 1, 1>>, :link_bag)
    end

    assert exception.message =~ "Tree-based RidBags are not supported by MarcoPolo"
  end

  ## Encoding

  test "encode_value/1: simple types" do
    # booleans
    assert bin(encode_value(true)) == <<1>>
    assert bin(encode_value(false)) == <<0>>

    # strings and binaries
    assert bin(encode_value("foo"))         == <<6, "foo">>
    assert bin(encode_value(<<0, 100, 1>>)) == <<6, 0, 100, 1>>

    # ints
    assert bin(encode_value(1)) == <<2>>
    assert bin(encode_value(1010)) == :small_ints.encode_zigzag_varint(1010)
    assert bin(encode_value(123456)) == :small_ints.encode_zigzag_varint(123456)

    # floats and doubles
    # (Elixir floats are always encoded as OrientDB doubles - 8 bytes)
    assert bin(encode_value(3.14)) == <<64, 9, 30, 184, 81, 235, 133, 31>>
    assert bin(encode_value({:float, 3.14})) == <<64, 72, 245, 195>>
    assert bin(encode_value({:double, 3.14})) == <<64, 9, 30, 184, 81, 235, 133, 31>>
  end

  test "encode_value/1: datetime" do
    datetime = %DateTime{year: 2015, month: 6, day: 30,
                         hour: 12, min: 03, sec: 29, msec: 901}
    assert bin(encode_value(datetime)) == :small_ints.encode_zigzag_varint(1435665809901)
  end

  test "encode_value/1: embedded document with no fields" do
    record = %Document{class: "Klass"}
    <<_version, record_content :: binary>> = @record_no_fields
    assert bin(encode_value(record)) == record_content
  end

  test "encode_value/1: embedded document with fields" do
    record = %Document{class: "foo", fields: %{"hello" => "world!", "int" => 12}}
    <<_version, record_content :: binary>> = @record_with_fields
    assert bin(encode_value(record)) == record_content
  end

  test "encode_value/1: embedded lists" do
    assert (bin(encode_value(["elem", true])) <> "foo") == @list
  end

  test "encode_value/1: embedded sets" do
    expected = <<4,            # number of items (zigzag, hence 2)
                 23,           # type of the elems in the list, OrientDB only supports ANY
                 0, 1,         # elem type (boolean) + value
                 7, 8, "elem", # elem type (string) + value
                 >>

    set = Enum.into([true, "elem"], HashSet.new)
    assert bin(encode_value(set)) == expected
  end

  test "encode_value/1: embedded maps" do
    # Note: order of keys in Elixir maps cannot be guaranteed, with the map
    # below it *should* be key2, key1, key3 (I guess because key2 is an
    # atom?). The test relies on that as there would be no other way to test the
    # encoding.

    expected = <<6,           # number of keys (zigzag, hence 2)
                 7,           # key type (string)
                 8, "key2",   # key
                 0, 0, 0, 0,  # ptr to data, 0 means null data
                 0,           # when ptr is null type is always 0 (which is boolean, but irrelevant)
                 7,           # key type (string)
                 8, "key1",   # key
                 0, 0, 0, 34, # ptr to data
                 7,           # data type (string)
                 7,           # key type (string)
                 8, "key3",   # key
                 0, 0, 0, 40, # ptr to data
                 1,           # data type (int)
                 10, "value", # key1 value
                 22,          # key3 value
                 >>

    # keys are converted to strings
    assert bin(encode_value(%{"key1" => "value", :key2 => nil, "key3" => 11})) == expected
  end

  test "encode_value/1: links" do
    rid = %RID{cluster_id: 100, position: 33}
    assert bin(encode_value(rid))
           == :small_ints.encode_zigzag_varint(100) <> :small_ints.encode_zigzag_varint(33)
  end

  test "encode_value/1: link lists and sets" do
    # Order matters because sets aren't ordered, so I'm testing against real
    # results.
    rids     = [%RID{cluster_id: 19, position: 4}, %RID{cluster_id: 0, position: 1}]
    set      = Enum.into(rids, HashSet.new)
    expected = <<4, :small_ints.encode_zigzag_varint(19) :: binary,
                    :small_ints.encode_zigzag_varint(4) :: binary,
                    :small_ints.encode_zigzag_varint(0) :: binary,
                    :small_ints.encode_zigzag_varint(1) :: binary>>

    assert bin(encode_value({:link_list, rids})) == expected
    assert bin(encode_value({:link_set, set}))   == expected
  end

  test "encode_value/1: link maps" do
    map = %{
      :foo  => %RID{cluster_id: 1, position: 2},
      "bar" => %RID{cluster_id: 3, position: 9},
    }
    expected = <<4, # nkeys, varint
                 7, 6, "foo", # key type + key value
                 :small_ints.encode_zigzag_varint(1) :: binary,
                 :small_ints.encode_zigzag_varint(2) :: binary, # rid
                 7, 6, "bar", # key type + key value
                 :small_ints.encode_zigzag_varint(3) :: binary,
                 :small_ints.encode_zigzag_varint(9) :: binary, # rid
                 >>

    assert bin(encode_value({:link_map, map})) == expected
  end

  test "encode_value/1: link bags" do
    rids = [%RID{cluster_id: 1, position: 22}, %RID{cluster_id: 9, position: 14}]
    data = <<1,                 # embedded link bag
             2 :: 32,           # size
             1 :: 16, 22 :: 64, # rid
             9 :: 16, 14 :: 64, # rid
             >>

    assert bin(encode_value({:link_bag, rids})) == data
  end

  defp bin(iodata) do
    IO.iodata_to_binary(iodata)
  end
end
