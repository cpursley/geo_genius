defmodule GeoGenius.ErrorTest do
  use ExUnit.Case, async: true

  test "names the SQL function that failed and keeps the reason" do
    error = GeoGenius.QueryError.exception(function: "areas_for_point", reason: :timeout)

    assert error.function == "areas_for_point"
    assert error.reason == :timeout
    assert Exception.message(error) =~ "areas_for_point"
  end
end
