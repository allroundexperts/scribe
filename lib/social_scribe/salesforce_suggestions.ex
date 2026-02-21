defmodule SocialScribe.SalesforceSuggestions do
  @moduledoc """
  Generates and formats Salesforce contact update suggestions by combining
  AI-extracted data with existing Salesforce contact information.
  """

  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.SalesforceApi
  alias SocialScribe.Accounts.UserCredential

  @field_labels %{
    "FirstName" => "First Name",
    "LastName" => "Last Name",
    "Email" => "Email",
    "Phone" => "Phone",
    "MobilePhone" => "Mobile Phone",
    "Title" => "Job Title",
    "MailingStreet" => "Mailing Street",
    "MailingCity" => "Mailing City",
    "MailingState" => "Mailing State",
    "MailingPostalCode" => "ZIP/Postal Code",
    "MailingCountry" => "Mailing Country"
  }

  @doc """
  Generates suggested updates for a Salesforce contact based on a meeting transcript.

  Returns a list of suggestion maps, each containing:
  - field: the Salesforce field name
  - label: human-readable field label
  - current_value: the existing value in Salesforce (or nil)
  - new_value: the AI-suggested value
  - context: explanation of where this was found in the transcript
  - apply: boolean indicating whether to apply this update (default false)
  """
  def generate_suggestions(%UserCredential{} = credential, contact_id, meeting) do
    with {:ok, contact} <- SalesforceApi.get_contact(credential, contact_id),
         {:ok, ai_suggestions} <- AIContentGeneratorApi.generate_salesforce_suggestions(meeting) do
      suggestions =
        ai_suggestions
        |> Enum.map(fn suggestion ->
          field = suggestion.field
          current_value = get_contact_field(contact, field)

          %{
            field: field,
            label: Map.get(@field_labels, field, field),
            current_value: current_value,
            new_value: suggestion.value,
            context: suggestion.context,
            apply: false
          }
        end)
        |> Enum.filter(fn suggestion ->
          # Only suggest updates where the new value is different from current
          suggestion.current_value != suggestion.new_value
        end)

      {:ok, suggestions}
    end
  end

  @doc """
  Generates suggestions from a meeting transcript without a specific contact.
  This is used when the user first opens the modal before selecting a contact.
  """
  def generate_suggestions_from_meeting(meeting) do
    case AIContentGeneratorApi.generate_salesforce_suggestions(meeting) do
      {:ok, ai_suggestions} ->
        suggestions =
          Enum.map(ai_suggestions, fn suggestion ->
            %{
              field: suggestion.field,
              label: Map.get(@field_labels, suggestion.field, suggestion.field),
              current_value: nil,
              new_value: suggestion.value,
              context: suggestion.context,
              apply: false
            }
          end)

        {:ok, suggestions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Merges AI-generated suggestions with existing contact data.
  Updates current_value and filters out suggestions where values haven't changed.
  """
  def merge_with_contact(suggestions, contact) do
    suggestions
    |> Enum.map(fn suggestion ->
      current_value = get_contact_field(contact, suggestion.field)
      %{suggestion | current_value: current_value}
    end)
    |> Enum.filter(fn suggestion ->
      # Only keep suggestions where the new value differs from current
      suggestion.current_value != suggestion.new_value
    end)
  end

  # Private functions

  defp get_contact_field(contact, field) do
    case field do
      "FirstName" -> contact.firstname
      "LastName" -> contact.lastname
      "Email" -> contact.email
      "Phone" -> contact.phone
      "MobilePhone" -> contact.mobile_phone
      "Title" -> contact.title
      "MailingStreet" -> contact.mailing_street
      "MailingCity" -> contact.mailing_city
      "MailingState" -> contact.mailing_state
      "MailingPostalCode" -> contact.mailing_postal_code
      "MailingCountry" -> contact.mailing_country
      _ -> nil
    end
  end
end
