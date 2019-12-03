require 'open3'
module Util
  class DbManager

    attr_accessor :con, :pub_con, :alt_pub_con, :event, :migration

    def initialize(params={})
      # Should only manage content of ctgov db schema
      if params[:event]
        @event = params[:event]
      else
        @event = Support::LoadEvent.create({:event_type=>'',:status=>'',:description=>'',:problems=>''})
      end
    end

    def dump_schema(schema_name)
      fm=Util::FileManager.new
      file_name="#{fm.pg_dump_file}_#{schema_name}"
      File.delete(file_name) if File.exist?(file_name)

      cmd="pg_dump aact -v -h localhost -p 5432 -U #{AACT::Application::AACT_DB_SUPER_USERNAME} --clean --exclude-table ar_internal_metadata --exclude-table schema_migrations --schema #{schema_name} -b -c -C -Fc -f #{file_name}"
      run_command_line(cmd)
    end

    def dump_database
      fm=Util::FileManager.new
      File.delete(fm.pg_dump_file) if File.exist?(fm.pg_dump_file)
      cmd="pg_dump #{AACT::Application::AACT_BACK_DATABASE_URL} -v -h localhost -p 5432 -U #{AACT::Application::AACT_DB_SUPER_USERNAME} --clean --exclude-table ar_internal_metadata --exclude-table schema_migrations --schema ctgov -b -c -C -Fc -f #{fm.pg_dump_file}"
      run_command_line(cmd)
      copy_dump_file_to_public_server
    end

    def copy_dump_file_to_public_server
      fm=Util::FileManager.new
      cmd="scp #{fm.pg_dump_file} ctti@#{AACT::Application::AACT_PUBLIC_HOSTNAME}:/aact-files/dump_files"
      system(cmd)
    end

    def refresh_public_db
      dump_file_name=Util::FileManager.new.pg_dump_file
      return nil if dump_file_name.nil?
      begin
        success_code=true
        revoke_db_privs   # Prevent users from logging in while db restore is running.

        # Refresh the aact_alt database first.  If something goes wrong, don't restore aact.
        terminate_alt_db_sessions

        begin
          #  Drop the existing ctgov schema with cascade. If dependencies exist on anything in ctgov, the restore won't be able to
          #  drop before replacing - resulting in a db of duplicate data.  Get rid of it using CASCADE' first.
          log "  dropping ctgov schema in alt public database..."
          cmd="DROP SCHEMA ctgov CASCADE;"
          PublicBase.establish_connection(AACT::Application::AACT_ALT_PUBLIC_DATABASE_URL).connection.execute(cmd)
          cmd="CREATE SCHEMA ctgov;"
          PublicBase.establish_connection(AACT::Application::AACT_ALT_PUBLIC_DATABASE_URL).connection.execute(cmd)
          cmd="GRANT USAGE ON SCHEMA ctgov TO read_only;"
          PublicBase.establish_connection(AACT::Application::AACT_ALT_PUBLIC_DATABASE_URL).connection.execute(cmd)
        rescue
        end
        log "  restoring alt public database..."
        cmd="pg_restore -c -j 5 -v -h #{public_host_name} -p 5432 -U #{AACT::Application::AACT_DB_SUPER_USERNAME}  -d aact_alt #{dump_file_name}"
        run_restore_command_line(cmd)

        log "  verifying alt public database..."
        public_studies_count = PublicBase.establish_connection(AACT::Application::AACT_ALT_PUBLIC_DATABASE_URL).connection.execute('select count(*) from studies;').first['count'].to_i

        if public_studies_count != background_study_count
          success_code = false
          msg = "SOMETHING WENT WRONG! PROBLEM IN PRODUCTION DATABASE: aact_alt.  Study count is #{public_studies_count}. Should be #{back_studies_count}"
          event.add_problem(msg)
          log msg
          grant_db_privs
          return false
        end
        log "  all systems go... we can update primary public aact...."

        # If all goes well with AACT_ALT DB, proceed with AACT

        terminate_db_sessions
        begin
          log "  dropping ctgov schema in main public database..."
          cmd="DROP SCHEMA ctgov CASCADE;"
          PublicBase.establish_connection(AACT::Application::AACT_PUBLIC_DATABASE_URL).connection.execute(cmd)
          cmd="CREATE SCHEMA ctgov;"
          PublicBase.establish_connection(AACT::Application::AACT_PUBLIC_DATABASE_URL).connection.execute(cmd)
        rescue
        end
        log "  restoring main public database..."
        cmd="pg_restore -c -j 5 -v -h #{public_host_name} -p 5432 -U #{AACT::Application::AACT_DB_SUPER_USERNAME}  -d #{public_db_name} #{dump_file_name}"
        run_restore_command_line(cmd)
        grant_db_privs
        return success_code
      rescue => error
        msg="#{error.message} (#{error.class} #{error.backtrace}"
        event.add_problem(msg)
        log msg
        grant_db_privs
        return false
      end
    end

    def background_study_count
      # partly to allow us to stub this value in tests
      Study.count
    end

    def grant_db_privs
      log "  db_manager:  granting ctgov schema access to read_only..."
      con=PublicBase.connection
      begin
        con.execute("GRANT USAGE ON SCHEMA ctgov TO read_only;")
      rescue
        con.execute("CREATE SCHEMA ctgov;")
        con.execute("GRANT USAGE ON SCHEMA ctgov TO read_only;")
      end
      con.execute("GRANT SELECT ON ALL TABLES IN SCHEMA ctgov TO read_only;")
      #con.execute("GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ctgov TO read_only;")
      con.execute("ALTER DATABASE aact CONNECTION LIMIT 200;")
      con.reset!
      con=PublicBase.establish_connection(AACT::Application::AACT_ALT_PUBLIC_DATABASE_URL).connection
      con.execute("GRANT USAGE ON SCHEMA ctgov TO read_only;")
      con.execute("GRANT SELECT ON ALL TABLES IN SCHEMA ctgov TO read_only;")
      con.execute("ALTER DATABASE aact_alt CONNECTION LIMIT 200;")
      con.reset!
    end

    def revoke_db_privs
      log "  db_manager: set connection limit so only db owner can login..."
      con=PublicBase.connection
      con.execute("ALTER DATABASE aact CONNECTION LIMIT 0;")
      con.execute("ALTER DATABASE aact_alt CONNECTION LIMIT 0;")
      con.reset!
    end

    def public_db_accessible?
      # we temporarily restrict access to the public db (set allowed connections to zero) during db restore.
      PublicBase.establish_connection(AACT::Application::AACT_BACK_DATABASE_URL).connection.execute("select datconnlimit from pg_database where datname='aact';").first["datconnlimit"].to_i > 0
    end

    def run_command_line(cmd)
      stdout, stderr, status = Open3.capture3(cmd)
      if status.exitstatus != 0
        event.add_problem("#{Time.zone.now}: #{stderr}")
        success_code=false
      end
    end

    def run_restore_command_line(cmd)
      stdout, stderr, status = Open3.capture3(cmd)
      if status.exitstatus != 0
          # Errors that report a db object doesn't already exist aren't real errors. Ignore those.  Look for real errors.
          real_errors = []
          stderr_array = stderr.split('pg_restore:')
          stderr_array.each {|line| real_errors << line  if line.include?('ERROR') && !line.include?("does not exist") }
          if !real_errors.empty?
            real_errors.each {|e| event.add_problem("#{Time.zone.now}: #{e}") }
            success_code=false
          end
        end
    end

    def log(msg)
      puts "#{Time.zone.now}: #{msg}"  # log to STDOUT
    end

    def terminate_db_sessions
      PublicBase.establish_connection(AACT::Application::AACT_PUBLIC_DATABASE_URL).connection.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = '#{public_db_name}' AND usename <> '#{AACT::Application::AACT_DB_SUPER_USERNAME}'")
    end

    def terminate_alt_db_sessions
      PublicBase.establish_connection(AACT::Application::AACT_ALT_PUBLIC_DATABASE_URL).connection.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = 'aact_alt' AND usename <> '#{AACT::Application::AACT_DB_SUPER_USERNAME}'")
    end

    def public_study_count
      begin
        pub_con.execute("select count(*) from studies").values.flatten.first.to_i
      rescue
        return 0
      end
    end

    def add_indexes_and_constraints
      add_indexes
      add_constraints
    end

    def add_indexes
      indexes.each{|index| m.add_index index.first, index.last  if !m.index_exists?(index.first, index.last)}
      #  Add indexes for all the nct_id columns.  If error raised cuz nct_id doesn't exist for the table, skip it.
      loadable_tables.each {|table_name|
        begin
          if table_name != 'studies'  # studies.nct_id unique index persists.  Don't add/remove it.
            if one_to_one_related_tables.include? table_name
              m.add_index table_name, 'nct_id', unique: true
            else
              m.add_index table_name, 'nct_id'
            end
            #  foreign keys that link to the studies table via the nct_id
            if !con.foreign_keys(table_name).map(&:column).include?("nct_id")
              m.add_foreign_key table_name,  "studies", column: "nct_id", primary_key: "nct_id", name: "#{table_name}_nct_id_fkey"
            end
          end
        rescue => e
          log(e)
          event.add_problem("#{Time.zone.now}: #{e}")
        end
      }
    end

    def add_constraints
      foreign_key_constraints.each { |constraint |
        child_table = constraint[:child_table]
        parent_table = constraint[:parent_table]
        child_column = constraint[:child_column]
        parent_column = constraint[:parent_column]
        begin
          m.add_foreign_key child_table,  parent_table, column: child_column, primary_key: parent_column, name: "#{child_table}_#{child_column}_fkey"
        rescue => e
          log(e)
          event.add_problem("#{Time.zone.now}: #{e}")
        end
      }
    end

    def remove_indexes_and_constraints
      loadable_tables.each {|table_name|
        # remove foreign key that links most tables to Studies table via the NCT ID
        begin
          con.remove_foreign_key table_name, column: :nct_id if con.foreign_keys(table_name).map(&:column).include?("nct_id")
        rescue => e
          log(e)
          event.add_problem("#{Time.zone.now}: #{e}")
        end

        con.indexes(table_name).each{|index|
          begin
            m.remove_index(index.table, index.columns) if !should_keep_index?(index) and m.index_exists?(index.table, index.columns)
          rescue => e
            log(e)
            event.add_problem("#{Time.zone.now}: #{e}")
          end
        }
      }
      # Remove foreign Key constraints
      foreign_key_constraints.each { |constraint|
        table = constraint[:child_table]
        column = constraint[:child_column]
        begin
          con.remove_foreign_key table, column: column if con.foreign_keys(table).map(&:column).include?(column)
        rescue => e
          log(e)
          event.add_problem("#{Time.zone.now}: #{e}")
        end
      }
    end

    def loadable_tables
      blacklist = %w(
        ar_internal_metadata
        schema_migrations
        data_definitions
        mesh_headings
        mesh_terms
        load_events
        mesh_terms
        mesh_headings
        sanity_checks
        statistics
        study_xml_records
        use_cases
        use_case_attachments
      )
      table_names=ActiveRecord::Base.connection.tables.reject{|table|blacklist.include?(table)}
    end

    def indexes
      # we drop all indexes to dramatically speed loads. This is used to recreate them after the load.  (better way?)
      [
         [:baseline_measurements, :dispersion_type],
         [:baseline_measurements, :param_type],
         [:baseline_measurements, :category],
         [:baseline_measurements, :classification],
         [:browse_conditions, :mesh_term],
         [:browse_conditions, :downcase_mesh_term],
         [:browse_interventions, :mesh_term],
         [:browse_interventions, :downcase_mesh_term],
         [:calculated_values, :actual_duration],
         [:calculated_values, :months_to_report_results],
         [:calculated_values, :number_of_facilities],
         [:central_contacts, :contact_type],
         [:conditions, :name],
         [:conditions, :downcase_name],
         [:design_groups, :group_type],
         [:design_outcomes, :measure],
         [:design_outcomes, :outcome_type],
         [:designs, :masking],
         [:designs, :subject_masked],
         [:designs, :caregiver_masked],
         [:designs, :investigator_masked],
         [:designs, :outcomes_assessor_masked],
         [:design_group_interventions, :design_group_id],
         [:design_group_interventions, :intervention_id],
         [:documents, :document_id],
         [:documents, :document_type],
         [:drop_withdrawals, :period],
         [:eligibilities, :gender],
         [:eligibilities, :healthy_volunteers],
         [:eligibilities, :minimum_age],
         [:eligibilities, :maximum_age],
         [:facilities, :status],
         [:facility_contacts, :contact_type],
         [:facilities, :name],
         [:facilities, :city],
         [:facilities, :state],
         [:facilities, :country],
         [:id_information, :id_type],
         [:interventions, :intervention_type],
         [:keywords, :name],
         [:keywords, :downcase_name],
         [:mesh_terms, :qualifier],
         [:mesh_terms, :description],
         [:mesh_terms, :mesh_term],
         [:mesh_terms, :downcase_mesh_term],
         [:mesh_headings, :qualifier],
         [:milestones, :period],
         [:outcomes, :param_type],
         [:outcome_analyses, :dispersion_type],
         [:outcome_analyses, :param_type],
         [:outcome_measurements, :dispersion_type],
         [:outcomes, :dispersion_type],
         [:overall_officials, :affiliation],
         [:outcome_measurements, :category],
         [:outcome_measurements, :classification],
         [:reported_events, :event_type],
         [:reported_events, :subjects_affected],
         [:responsible_parties, :organization],
         [:responsible_parties, :responsible_party_type],
         [:result_contacts, :organization],
         [:result_groups, :result_type],
         [:sponsors, :agency_class],
         [:sponsors, :name],
         [:studies, :enrollment_type],
         [:studies, :overall_status],
         [:studies, :phase],
         [:studies, :last_known_status],
         [:studies, :primary_completion_date_type],
         [:studies, :source],
         [:studies, :study_type],
         [:studies, :study_first_submitted_date],
         [:studies, :results_first_submitted_date],
         [:studies, :disposition_first_submitted_date],
         [:studies, :last_update_submitted_date],
         [:studies, :results_first_submitted_qc_date],
         [:studies, :study_first_submitted_qc_date],
         [:studies, :last_update_submitted_qc_date],
         [:study_references, :pmid],
         [:study_references, :reference_type],
      ]
    end

    def foreign_key_constraints
      # we drop all constraints to dramatically speed loads. This is used to recreate them after the load.  (better way?)
      [
        {:child_table => 'baseline_counts',            :parent_table => 'result_groups',    :child_column => 'result_group_id',     :parent_column => 'id'},
        {:child_table => 'baseline_measurements',      :parent_table => 'result_groups',    :child_column => 'result_group_id',     :parent_column => 'id'},
        {:child_table => 'design_group_interventions', :parent_table => 'interventions',    :child_column => 'intervention_id',     :parent_column => 'id'},
        {:child_table => 'design_group_interventions', :parent_table => 'design_groups',    :child_column => 'design_group_id',     :parent_column => 'id'},
        {:child_table => 'drop_withdrawals',           :parent_table => 'result_groups',    :child_column => 'result_group_id',     :parent_column => 'id'},
        {:child_table => 'reported_events',            :parent_table => 'result_groups',    :child_column => 'result_group_id',     :parent_column => 'id'},
        {:child_table => 'facility_contacts',          :parent_table => 'facilities',       :child_column => 'facility_id',         :parent_column => 'id'},
        {:child_table => 'facility_investigators',     :parent_table => 'facilities',       :child_column => 'facility_id',         :parent_column => 'id'},
        {:child_table => 'intervention_other_names',   :parent_table => 'interventions',    :child_column => 'intervention_id',     :parent_column => 'id'},
        {:child_table => 'milestones',                 :parent_table => 'result_groups',    :child_column => 'result_group_id',     :parent_column => 'id'},
        {:child_table => 'outcome_analyses',           :parent_table => 'outcomes',         :child_column => 'outcome_id',          :parent_column => 'id'},
        {:child_table => 'outcome_analysis_groups',    :parent_table => 'result_groups',    :child_column => 'result_group_id',     :parent_column => 'id'},
        {:child_table => 'outcome_analysis_groups',    :parent_table => 'outcome_analyses', :child_column => 'outcome_analysis_id', :parent_column => 'id'},
        {:child_table => 'outcome_counts',             :parent_table => 'outcomes',         :child_column => 'outcome_id',          :parent_column => 'id'},
        {:child_table => 'outcome_counts',             :parent_table => 'result_groups',    :child_column => 'result_group_id',     :parent_column => 'id'},
        {:child_table => 'outcome_measurements',       :parent_table => 'outcomes',         :child_column => 'outcome_id',          :parent_column => 'id'},
        {:child_table => 'outcome_measurements',       :parent_table => 'result_groups',    :child_column => 'result_group_id',     :parent_column => 'id'},
      ]
    end

    def one_to_one_related_tables
      [ 'brief_summaries', 'designs','detailed_descriptions', 'eligibilities', 'participant_flows', 'calculated_values' ]
    end

    def should_keep_index?(index)
      return true if index.table=='studies' and index.columns==['nct_id']
      return true if index.table=='study_xml_records' and index.columns==['nct_id']
      return true if index.table=='study_xml_records' and index.columns==['created_study_at']
      return true if index.table=='sanity_checks'
      false
    end

    def indexes_for(table_name)
      con.execute("select t.relname as table_name, i.relname as index_name, a.attname as column_name, ix.indisprimary as is_primary, ix.indisunique as is_unique from pg_class t, pg_class i, pg_index ix, pg_attribute a where t.oid = ix.indrelid and i.oid = ix.indexrelid and a.attrelid = t.oid and a.attnum = ANY(ix.indkey) and t.relkind = 'r' and t.relname = '#{table_name}';")
    end

    def con
      return @con if @con and @con.active?
      @con = ActiveRecord::Base.establish_connection(AACT::Application::AACT_BACK_DATABASE_URL).connection
      @con.schema_search_path='ctgov'
      return @con
    end

    def m
      @migration ||= ActiveRecord::Migration.new
    end

    def pub_con
      @pub_con ||= PublicBase.establish_connection(AACT::Application::AACT_PUBLIC_DATABASE_URL).connection
    end

    def alt_pub_con
      @alt_pub_con ||= PublicBase.establish_connection(AACT::Application::AACT_ALT_PUBLIC_DATABASE_URL).connection
    end

    def public_host_name
      AACT::Application::AACT_PUBLIC_HOSTNAME
    end

    def public_db_name
      AACT::Application::AACT_PUBLIC_DATABASE_NAME
    end

  end

end
