require "test_helper"

class BookSelectionRenderingTest < ActionDispatch::IntegrationTest
  test "the browser form accepts only EPUBs and cannot upload named file fields" do
    get "/", headers: { "Accept-Language" => "en" }

    assert_response :success
    assert_select ".book-picker" do
      assert_select "input[type=file][accept='.epub,application/epub+zip'][multiple]", 2
      assert_select "input[type=file][name]", 0
      assert_select "input[type=file][webkitdirectory][directory]", 1
      assert_select "template[data-book-picker-target=row]", 1
      assert_select "[data-book-picker-target=empty]", text: /No books queued/
      assert_select "[data-book-picker-target=count]", "0"
      assert_select "[role=alert][hidden]", minimum: 1
      assert_select "[data-book-picker-target=submit]", "Convert now"
    end
  end

  test "selection keys are available in both supported locales" do
    keys = ->(locale) { I18n.t("form", locale: locale).keys.sort }
    assert_equal keys.call(:en), keys.call(:"pt-BR")
    get "/", headers: { "Accept-Language" => "pt-BR" }
    assert_select "label[for=book-files]", "Arquivo do livro (EPUB)"
    assert_select "[data-book-picker-target=submit]", "Converter agora"
  end
end
