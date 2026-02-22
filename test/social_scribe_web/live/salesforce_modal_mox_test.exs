defmodule SocialScribeWeb.SalesforceModalMoxTest do
  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures
  import Mox

  setup :verify_on_exit!

  describe "Salesforce Modal with mocked API" do
    setup %{conn: conn} do
      user = user_fixture()
      salesforce_credential = salesforce_credential_fixture(%{user_id: user.id})
      meeting = meeting_fixture_with_transcript(user)

      %{
        conn: log_in_user(conn, user),
        user: user,
        meeting: meeting,
        salesforce_credential: salesforce_credential
      }
    end

    test "search_contacts returns mocked results", %{conn: conn, meeting: meeting} do
      mock_contacts = [
        %{
          id: "003xx000004TMM6AAO",
          name: "John Doe",
          firstname: "John",
          lastname: "Doe",
          email: "john@example.com",
          phone: nil,
          mobile_phone: "555-0123",
          title: "VP of Sales",
          company: "Acme Corp"
        },
        %{
          id: "003xx000004TMM7AAO",
          name: "Jane Smith",
          firstname: "Jane",
          lastname: "Smith",
          email: "jane@example.com",
          phone: "555-1234",
          mobile_phone: nil,
          title: "Director of Marketing",
          company: "Tech Inc"
        }
      ]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, query ->
        assert query == "John"
        {:ok, mock_contacts}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      # Trigger contact search
      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      # Wait for async update
      :timer.sleep(200)

      # Re-render to see updates
      html = render(view)

      # Verify contacts are displayed
      assert html =~ "John Doe"
      assert html =~ "Jane Smith"
    end

    test "search_contacts handles API error gracefully", %{conn: conn, meeting: meeting} do
      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:error, {:api_error, 500, %{"message" => "Internal server error"}}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Test"})

      :timer.sleep(200)

      html = render(view)

      # Should show error message
      assert html =~ "Failed to search contacts"
    end

    test "selecting contact triggers suggestion generation", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "003xx000004TMM6AAO",
        name: "John Doe",
        firstname: "John",
        lastname: "Doe",
        email: "john@example.com",
        phone: nil,
        mobile_phone: "555-0123",
        title: "VP of Sales",
        company: "Acme Corp"
      }

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting ->
        {:ok, [%{field: "Phone", value: "555-1234", context: "Mentioned phone number during call"}]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      :timer.sleep(100)

      # Select the contact using the actual phx-click selector
      view
      |> element("button[phx-click='select_contact'][phx-value-id='003xx000004TMM6AAO']")
      |> render_click()

      :timer.sleep(200)

      html = render(view)

      # Should show the selected contact name
      assert html =~ "John Doe"
    end

    test "get_contact returns contact details", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "003xx000004TMM6AAO",
        name: "John Doe",
        firstname: "John",
        lastname: "Doe",
        email: "john@example.com",
        phone: nil,
        mobile_phone: "555-0123",
        title: "VP of Sales",
        company: "Acme Corp"
      }

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting ->
        {:ok, [%{field: "Phone", value: "555-1234", context: "Mentioned phone number during call"}]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      # This would typically be triggered by selecting a contact
      send(view.pid, {:generate_salesforce_suggestions, mock_contact, meeting, nil})

      :timer.sleep(100)

      html = render(view)

      # Should show the contact name indicating successful processing
      assert html =~ "John Doe"
    end
  end

  describe "Salesforce API behavior delegation" do
    setup do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id})
      %{credential: credential}
    end

    test "search_contacts delegates to implementation", %{credential: credential} do
      expected = [%{id: "003xx000004TMM6AAO", name: "Test User", firstname: "Test", lastname: "User"}]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _cred, query ->
        assert query == "test query"
        {:ok, expected}
      end)

      assert {:ok, ^expected} =
               SocialScribe.SalesforceApiBehaviour.search_contacts(credential, "test query")
    end

    test "get_contact delegates to implementation", %{credential: credential} do
      expected = %{id: "003xx000004TMM6AAO", firstname: "John", lastname: "Doe"}

      SocialScribe.SalesforceApiMock
      |> expect(:get_contact, fn _cred, contact_id ->
        assert contact_id == "003xx000004TMM6AAO"
        {:ok, expected}
      end)

      assert {:ok, ^expected} = SocialScribe.SalesforceApiBehaviour.get_contact(credential, "003xx000004TMM6AAO")
    end

    test "update_contact delegates to implementation", %{credential: credential} do
      updates = %{"Phone" => "555-1234", "Title" => "New Title"}
      expected = %{id: "003xx000004TMM6AAO", phone: "555-1234", title: "New Title"}

      SocialScribe.SalesforceApiMock
      |> expect(:update_contact, fn _cred, contact_id, upd ->
        assert contact_id == "003xx000004TMM6AAO"
        assert upd == updates
        {:ok, expected}
      end)

      assert {:ok, ^expected} =
               SocialScribe.SalesforceApiBehaviour.update_contact(credential, "003xx000004TMM6AAO", updates)
    end

    test "apply_updates delegates to implementation", %{credential: credential} do
      updates_list = [
        %{field: "Phone", new_value: "555-1234", apply: true},
        %{field: "Email", new_value: "test@example.com", apply: false}
      ]

      SocialScribe.SalesforceApiMock
      |> expect(:apply_updates, fn _cred, contact_id, list ->
        assert contact_id == "003xx000004TMM6AAO"
        assert list == updates_list
        {:ok, %{id: "003xx000004TMM6AAO"}}
      end)

      assert {:ok, _} =
               SocialScribe.SalesforceApiBehaviour.apply_updates(credential, "003xx000004TMM6AAO", updates_list)
    end
  end

  # Helper function to create a meeting with transcript for testing
  defp meeting_fixture_with_transcript(user) do
    meeting = meeting_fixture(%{})

    calendar_event = SocialScribe.Calendar.get_calendar_event!(meeting.calendar_event_id)

    {:ok, _updated_event} =
      SocialScribe.Calendar.update_calendar_event(calendar_event, %{user_id: user.id})

    meeting_transcript_fixture(%{
      meeting_id: meeting.id,
      content: %{
        "data" => [
          %{
            "speaker" => "John Doe",
            "words" => [
              %{"text" => "Hello,"},
              %{"text" => "my"},
              %{"text" => "phone"},
              %{"text" => "is"},
              %{"text" => "555-1234"}
            ]
          }
        ]
      }
    })

    SocialScribe.Meetings.get_meeting_with_details(meeting.id)
  end
end
