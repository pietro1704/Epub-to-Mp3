# frozen_string_literal: true

require "minitest/autorun"
require "rexml/document"

# The mobile apps open the book formats the converter supports.
class MobileFileAssociationsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BOOK_MIME_TYPES = %w[application/epub+zip application/pdf].freeze

  def xml(path)
    REXML::Document.new(File.read(File.join(ROOT, path)))
  end

  def android_attribute(node, name)
    node.attribute(name, "http://schemas.android.com/apk/res/android")&.value
  end

  def mime_types_for(action)
    manifest = xml("flutter_app/android/app/src/main/AndroidManifest.xml")
    activity = REXML::XPath.first(manifest, "/manifest/application/activity")
    refute_nil activity, "MainActivity declaration is missing"
    activity.get_elements("intent-filter").each_with_object([]) do |filter, mimes|
      actions = filter.get_elements("action").filter_map { |node| android_attribute(node, "name") }
      next unless actions.include?(action)

      mimes.concat(filter.get_elements("data").filter_map { |node| android_attribute(node, "mimeType") })
    end
  end

  def test_android_app_is_associated_with_supported_book_documents
    assert_empty BOOK_MIME_TYPES - mime_types_for("android.intent.action.VIEW")
    assert_empty BOOK_MIME_TYPES - mime_types_for("android.intent.action.SEND")
  end

  # Reads LSItemContentTypes from each CFBundleDocumentTypes dictionary of the XML plist.
  def test_ios_app_declares_document_types_for_supported_book_documents
    plist = xml("ios/EpubToMp3/EpubToMp3/Resources/Info.plist")
    root = REXML::XPath.first(plist, "/plist/dict")
    key = root.get_elements("key").find { |node| node.text == "CFBundleDocumentTypes" }
    refute_nil key, "CFBundleDocumentTypes is missing"
    array = key.next_element
    assert_equal "array", array.name
    declared = array.get_elements("dict").flat_map do |dictionary|
      types_key = dictionary.get_elements("key").find { |node| node.text == "LSItemContentTypes" }
      types_key ? types_key.next_element.get_elements("string").map(&:text) : []
    end

    %w[org.idpf.epub-container com.apple.ibooks.epub public.epub com.adobe.pdf public.pdf].each do |type|
      assert_includes declared, type
    end
  end

  def test_android_shortcut_labels_use_string_resources
    shortcut = REXML::XPath.first(xml("flutter_app/android/app/src/main/res/xml/shortcuts.xml"), "/shortcuts/shortcut")
    refute_nil shortcut

    %w[shortcutShortLabel shortcutLongLabel].each do |attribute|
      value = android_attribute(shortcut, attribute)
      refute_nil value, "Android #{attribute} is missing"
      assert value.start_with?("@string/"), "Android #{attribute} must reference a string resource, not a literal"
    end
  end
end
