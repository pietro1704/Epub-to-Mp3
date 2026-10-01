class Book < ApplicationRecord
  enum :status, { imported: "imported", converting: "converting", ready: "ready", failed: "failed" }, default: :imported
  validates :title, presence: true
  validates :source_path, presence: true
end
