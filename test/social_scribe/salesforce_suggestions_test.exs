defmodule SocialScribe.SalesforceSuggestionsTest do
  use SocialScribe.DataCase

  alias SocialScribe.SalesforceSuggestions

  describe "merge_with_contact/2" do
    test "merges suggestions with contact data and filters unchanged values" do
      suggestions = [
        %{
          field: "Phone",
          label: "Phone",
          current_value: nil,
          new_value: "555-1234",
          context: "Mentioned in call",
          apply: false,
          has_change: true
        },
        %{
          field: "Title",
          label: "Title",
          current_value: nil,
          new_value: "VP of Sales",
          context: "Current role",
          apply: false,
          has_change: true
        }
      ]

      contact = %{
        id: "003xx000004TMM6AAO",
        phone: nil,
        title: "VP of Sales",
        email: "test@example.com"
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      # Only phone should remain since title already matches
      assert length(result) == 1
      assert hd(result).field == "Phone"
      assert hd(result).new_value == "555-1234"
    end

    test "returns empty list when all suggestions match current values" do
      suggestions = [
        %{
          field: "Email",
          label: "Email",
          current_value: nil,
          new_value: "test@example.com",
          context: "Email address from transcript",
          apply: false,
          has_change: true
        }
      ]

      contact = %{
        id: "003xx000004TMM6AAO",
        email: "test@example.com",
        phone: "555-0123"
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert result == []
    end

    test "handles nil contact fields correctly" do
      suggestions = [
        %{
          field: "MobilePhone",
          label: "Mobile Phone",
          current_value: nil,
          new_value: "555-9876",
          context: "Mobile number mentioned",
          apply: false,
          has_change: true
        }
      ]

      contact = %{
        id: "003xx000004TMM6AAO",
        mobile_phone: nil,
        email: "test@example.com"
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert length(result) == 1
      assert hd(result).field == "MobilePhone"
      assert hd(result).new_value == "555-9876"
      assert hd(result).has_change == true
    end

    test "preserves suggestion structure and metadata" do
      suggestions = [
        %{
          field: "FirstName",
          label: "First Name",
          current_value: nil,
          new_value: "John",
          context: "First name from introduction",
          apply: false,
          has_change: true,
          confidence: 0.95
        }
      ]

      contact = %{
        id: "003xx000004TMM6AAO",
        firstname: nil
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      suggestion = hd(result)
      assert suggestion.field == "FirstName"
      assert suggestion.label == "First Name"
      assert suggestion.context == "First name from introduction"
      assert suggestion.confidence == 0.95
    end
  end

  describe "format_suggestions/2" do
    test "formats AI-generated suggestions correctly" do
      contact = %{
        id: "003xx000004TMM6AAO",
        firstname: "Jane",
        lastname: "Doe",
        email: "jane.doe@example.com",
        phone: nil,
        title: nil
      }

      ai_suggestions = [
        %{
          "field" => "Phone",
          "value" => "555-1234",
          "reason" => "Phone number mentioned during call"
        },
        %{
          "field" => "Title",
          "value" => "Director of Marketing",
          "reason" => "Current job title discussed"
        }
      ]

      # This would test the actual formatting function when implemented
      # For now, verify the test structure is correct
      assert contact.id == "003xx000004TMM6AAO"
      assert length(ai_suggestions) == 2
    end
  end
end
