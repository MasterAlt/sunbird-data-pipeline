require 'pry'
require 'hashie'
require 'elasticsearch'
require 'mysql2'
require 'yaml'

require_relative '../utils/ep_logging.rb'

module EcosystemPlatform
  module Jobs
    class AgePopulator
      PROGNAME = 'age_populator.jobs.ep'
      include EcosystemPlatform::Utils::EPLogging
      def self.perform(index="ecosystem-*")
        begin
          logger.start_task
          logger.info("INITIALIZING CLIENT")
          # TODO Terrible terrible
          # will be replaced by a config module
          db_config = YAML::load_file(File.expand_path('../../../../config/database.yml',__FILE__))
          @db_client = Mysql2::Client.new(db_config)
          @client = ::Elasticsearch::Client.new(host:ENV['ES_HOST']||'localhost',log: false)
          @client.indices.refresh index: index
          logger.info("SEARCHING EVENTS FOR AGE ")
          response = @client.search({
            index: index,
            type: 'events_v1',
            size: 1000000,
            body: {
              "query"=> {
                "constant_score" => {
                  "filter" =>
                    {
                    "and" => {
                      "filters" => [
                        {
                          "exists" => {
                            "field" => "uid"
                          }
                        },
                        {
                          "not" => {
                            "filter" => {
                              "term" => {
                                "uid" => ""
                              }
                            }
                          }
                        },
                        {
                          "missing" => {
                            "field" => "udata.age",
                            "existence" => true,
                            "null_value" => true
                          }
                        },
                        {
                          "missing" => {
                            "field" => "flags.age_processed"
                          }
                        }
                      ]
                    }
                  }
                }
              }
            }
          })
          response = Hashie::Mash.new response
          logger.info "FOUND #{response.hits.total} hits."
          response.hits.hits.each do |hit|
            uid = hit._source.uid
            results = @db_client.query("SELECT * FROM children where encoded_id = '#{uid}'")
            child = Hashie::Mash.new results.first
            result = @client.update({
                index: hit._index,
                type: hit._type,
                id: hit._id,
                body: request_body(child)
            })
            logger.info "<- RESULT #{result}"
            end
          end
          logger.end_task
        rescue => e
          logger.error(e,{backtrace: e.backtrace[0..4]})
          logger.end_task
        end
      end

	def request_body(child)
		data = Hash.new
		doc = {doc: {flags: {age_processed: true}}}
        if(child.dob)
            time_then = Time.strptime(hit._source.ts,'%Y-%m-%dT%H:%M:%S%z')
            age_then = time_then - child.dob
			seconds_in_a_year = 31556952
			completed_years = (age_then / seconds_in_a_year).floor
			data[:age]= age_then
			data[:dob]= child.dob
			data[:completed_age]= completed_years
            logger.info "-> UPDATE #{hit._source.eid} #{hit._id}"
        end
        data[:gender]=child.gender if child.gender
        doc[:doc][:udata]=data unless data.empty?
        return doc
	end
    end
  end
end

