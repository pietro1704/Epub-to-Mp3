class CreateBooks < ActiveRecord::Migration[8.1]
  def change
    create_table :books do |t|
      t.string :title, null: false
      t.string :author
      t.string :source_path, null: false
      t.string :status, null: false, default: "imported"
      t.string :job_id
      t.string :error_message
      t.timestamps
    end
    add_index :books, :status
    add_index :books, :job_id
  end
end
