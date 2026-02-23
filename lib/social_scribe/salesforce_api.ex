defmodule SocialScribe.SalesforceApi do
  @moduledoc """
  Salesforce API integration module.
  Provides functions for interacting with Salesforce REST API.
  """

  @behaviour SocialScribe.SalesforceApiBehaviour

  require Logger
  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.SalesforceTokenRefresher

  # Salesforce API version (optional, defaults to v60.0)
  defp salesforce_api_version do
    "v60.0"
  end

  @doc """
  Updates a contact in Salesforce.
  """
  def update_contact(%UserCredential{} = credential, contact_id, updates) do
    with_token_refresh(credential, fn cred ->
      url = "#{get_instance_url(cred)}/services/data/#{salesforce_api_version()}/sobjects/Contact/#{contact_id}"

      headers = [
        {"Authorization", "Bearer #{cred.token}"},
        {"Content-Type", "application/json"}
      ]

      case Tesla.patch(http_client(), url, updates, headers: headers) do
        {:ok, %Tesla.Env{status: 204}} ->
          {:ok, %{}}

        {:ok, %Tesla.Env{status: 401, body: body}} ->
          {:error, {:api_error, 401, body}}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          Logger.error("Failed to update Salesforce contact: #{status} - #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("HTTP error updating Salesforce contact: #{inspect(reason)}")
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Searches for contacts in Salesforce by name or email.
  """
  def search_contacts(%UserCredential{} = credential, query) do
    with_token_refresh(credential, fn cred ->
      Logger.info("Salesforce search starting...")
      Logger.info("Credential UID: #{cred.uid}")
      Logger.info("Token exists: #{not is_nil(cred.token)}")
      Logger.info("Token length: #{cred.token && String.length(cred.token) || 0}")

      perform_contact_search(cred, query)
    end)
  end

  defp perform_contact_search(%UserCredential{} = credential, query) do
    # Use SOQL query for contact search
    escaped_query = String.replace(query, "'", "\\'")

    soql_query = """
    SELECT Id, Name, FirstName, LastName, Email, Phone, MobilePhone, Title
    FROM Contact
    WHERE (Name LIKE '%#{escaped_query}%'
       OR Email LIKE '%#{escaped_query}%'
       OR FirstName LIKE '%#{escaped_query}%'
       OR LastName LIKE '%#{escaped_query}%')
    LIMIT 50
    """

    # Use the proper instance URL
    instance_url = get_instance_url(credential)
    url = "#{instance_url}/services/data/#{salesforce_api_version()}/query"
    Logger.info("Salesforce query URL: #{url}")

    headers = [
      {"Authorization", "Bearer #{credential.token}"},
      {"Content-Type", "application/json"}
    ]

    params = [q: soql_query]

    case Tesla.get(http_client(), url, query: params, headers: headers) do
      {:ok, %Tesla.Env{status: 200, body: %{"records" => records}}} ->
        formatted_contacts = Enum.map(records, &format_contact/1)
        {:ok, formatted_contacts}

      {:ok, %Tesla.Env{status: 200, body: %{"totalSize" => 0}}} ->
        {:ok, []}

      {:ok, %Tesla.Env{status: 401, body: body}} ->
        {:error, {:api_error, 401, body}}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        Logger.error("Salesforce contact search failed: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Salesforce contact search error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Gets a specific contact by ID from Salesforce.
  """
  def get_contact(%UserCredential{} = credential, contact_id) do
    with_token_refresh(credential, fn cred ->
      url = "#{get_instance_url(cred)}/services/data/#{salesforce_api_version()}/sobjects/Contact/#{contact_id}"

      headers = [
        {"Authorization", "Bearer #{cred.token}"},
        {"Content-Type", "application/json"}
      ]

      case Tesla.get(http_client(), url, headers: headers) do
        {:ok, %Tesla.Env{status: 200, body: body}} ->
          {:ok, format_contact(body)}

        {:ok, %Tesla.Env{status: 401, body: body}} ->
          {:error, {:api_error, 401, body}}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          Logger.error("Failed to get Salesforce contact: #{status} - #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("HTTP error getting Salesforce contact: #{inspect(reason)}")
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Batch updates multiple properties on a contact.
  This is a convenience wrapper around update_contact/3.
  """
  def apply_updates(%UserCredential{} = credential, contact_id, updates_list)
      when is_list(updates_list) do
    updates_map =
      updates_list
      |> Enum.filter(fn update -> update[:apply] == true end)
      |> Enum.reduce(%{}, fn update, acc ->
        Map.put(acc, update.field, update.new_value)
      end)

    if map_size(updates_map) > 0 do
      update_contact(credential, contact_id, updates_map)
    else
      {:ok, :no_updates}
    end
  end

  # Format contact data from Salesforce API response
  defp format_contact(contact) do
    %{
      id: contact["Id"],
      name: contact["Name"],
      firstname: contact["FirstName"],
      lastname: contact["LastName"],
      email: contact["Email"],
      phone: contact["Phone"],
      mobile_phone: contact["MobilePhone"],
      title: contact["Title"],
      company: get_in(contact, ["Account", "Name"]) || contact["AccountId"],
      mailing_street: contact["MailingStreet"],
      mailing_city: contact["MailingCity"],
      mailing_state: contact["MailingState"],
      mailing_postal_code: contact["MailingPostalCode"],
      mailing_country: contact["MailingCountry"]
    }
  end

  # Private functions

  defp get_instance_url(%UserCredential{metadata: %{"instance_url" => url}}) when is_binary(url) and byte_size(url) > 0 do
    url
  end
  defp get_instance_url(%UserCredential{}), do: raise "Salesforce instance_url missing from credential metadata!"

  defp http_client do
    Tesla.client([
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Timeout, timeout: 30_000},
      Tesla.Middleware.Logger
    ])
  end

  # Wrapper that handles token refresh on auth errors
  # Tries the API call, and if it fails with 401 or INVALID_SESSION_ID, refreshes token and retries once
  defp with_token_refresh(%UserCredential{} = credential, api_call) do
    with {:ok, credential} <- SalesforceTokenRefresher.ensure_valid_token(credential) do
      case api_call.(credential) do
        {:error, {:api_error, status, body}} when status in [401, 400] ->
          if is_token_error?(body) do
            Logger.info("Salesforce token expired, refreshing and retrying...")
            retry_with_fresh_token(credential, api_call)
          else
            Logger.error("Salesforce API error: #{status} - #{inspect(body)}")
            {:error, {:api_error, status, body}}
          end

        other ->
          other
      end
    end
  end

  defp retry_with_fresh_token(credential, api_call) do
    case SalesforceTokenRefresher.refresh_credential(credential) do
      {:ok, refreshed_credential} ->
        case api_call.(refreshed_credential) do
          {:error, {:api_error, status, body}} ->
            Logger.error("Salesforce API error after refresh: #{status} - #{inspect(body)}")
            {:error, {:api_error, status, body}}

          {:error, {:http_error, reason}} ->
            Logger.error("Salesforce HTTP error after refresh: #{inspect(reason)}")
            {:error, {:http_error, reason}}

          success ->
            success
        end

      {:error, refresh_error} ->
        Logger.error("Failed to refresh Salesforce token: #{inspect(refresh_error)}")
        {:error, {:token_refresh_failed, refresh_error}}
    end
  end

  defp is_token_error?(%{"message" => "Session expired or invalid"}), do: true
  defp is_token_error?(%{"errorCode" => "INVALID_SESSION_ID"}), do: true
  defp is_token_error?(body) when is_list(body) do
    Enum.any?(body, fn
      %{"message" => "Session expired or invalid"} -> true
      %{"errorCode" => "INVALID_SESSION_ID"} -> true
      _ -> false
    end)
  end
  defp is_token_error?(%{"message" => msg}) when is_binary(msg) do
    String.contains?(String.downcase(msg), ["session expired", "invalid", "token", "unauthorized"])
  end
  defp is_token_error?(_), do: false
end
