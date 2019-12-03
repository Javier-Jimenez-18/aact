class CreateCriteriaTable < ActiveRecord::Migration

  def change

    create_table "ctgov.criteria", force: :cascade do |t|
      t.string  "nct_id"
      t.integer "parent_id"
      t.integer "level"
      t.integer "order_number"
      t.string  "criterium_type"
      t.string  "name"
      t.string  "downcase_name"
    end

  end

end
