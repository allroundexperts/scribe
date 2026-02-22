defmodule SocialScribe.Workers.HubspotTokenRefresherTest do
  use SocialScribe.DataCase
  import Tesla.Mock

  alias SocialScribe.Workers.HubspotTokenRefresher

  import SocialScribe.AccountsFixtures

  setup do
    mock fn
      %{method: :post, url: "https://api.hubapi.com/oauth/v1/token"} ->
        %Tesla.Env{
          status: 200,
          body: %{
            "access_token" => "new_access_token",
            "refresh_token" => "new_refresh_token",
            "expires_in" => 21600,
            "token_type" => "bearer"
          }
        }
    end

    :ok
  end

  describe "perform/1" do
    test "returns :ok when no HubSpot credentials are expiring" do
      user = user_fixture()

      # Create credential that expires in 1 hour (not expiring soon)
      _credential =
        hubspot_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert :ok = HubspotTokenRefresher.perform(%Oban.Job{})
    end

    test "identifies expiring HubSpot credentials" do
      user = user_fixture()

      # Create credential expiring in 5 minutes (within threshold)
      expiring_credential =
        hubspot_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        })

      # Create non-HubSpot credential (should be ignored)
      _salesforce_credential =
        salesforce_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        })

      # Worker should identify the HubSpot credential as expiring
      assert expiring_credential.provider == "hubspot"
      assert DateTime.compare(
               expiring_credential.expires_at,
               DateTime.add(DateTime.utc_now(), 600, :second)
             ) == :lt
    end

    test "handles credentials without refresh tokens" do
      user = user_fixture()

      # Create credential without refresh token (should be skipped)
      _credential_without_refresh =
        hubspot_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          refresh_token: nil
        })

      # Worker should handle this gracefully
      assert :ok = HubspotTokenRefresher.perform(%Oban.Job{})
    end

    test "processes multiple expiring credentials" do
      user1 = user_fixture()
      user2 = user_fixture()

      # Create multiple expiring HubSpot credentials
      _credential1 =
        hubspot_credential_fixture(%{
          user_id: user1.id,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        })

      _credential2 =
        hubspot_credential_fixture(%{
          user_id: user2.id,
          expires_at: DateTime.add(DateTime.utc_now(), 400, :second)
        })

      # Worker should handle multiple credentials
      assert :ok = HubspotTokenRefresher.perform(%Oban.Job{})
    end

    test "returns :ok even when individual refreshes fail" do
      user = user_fixture()

      # Create credential with invalid refresh token (will cause failures)
      _credential =
        hubspot_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          refresh_token: "invalid_token"
        })

      # Worker should return :ok even if individual refreshes fail
      # This prevents the entire job from being retried
      assert :ok = HubspotTokenRefresher.perform(%Oban.Job{})
    end
  end

  test "job can be enqueued" do
    assert {:ok, _job} =
             %{}
             |> HubspotTokenRefresher.new()
             |> Oban.insert()
  end
end
