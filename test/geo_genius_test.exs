defmodule GeoGeniusTest do
  use ExUnit.Case, async: true

  test "the test database has postgis and pg_trgm available" do
    %{rows: rows} =
      GeoGenius.TestRepo.query!(
        "SELECT name FROM pg_available_extensions WHERE name = ANY($1)",
        [["postgis", "pg_trgm"]]
      )

    assert Enum.sort(List.flatten(rows)) == ["pg_trgm", "postgis"]
  end
end
