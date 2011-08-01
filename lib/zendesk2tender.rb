#
# Produce a Tender import archive by collecting tickets and discussions from
# the ZenDesk API. Requires the ZenDesk subdomain and login credentials.
#
# For more info: https://help.tenderapp.com/faqs/setup-installation/importing
#
#   Usage:
#     zendesk2tender -e <email> -p <password> -s <subdomain>
#
#   `zendesk2tender --help' displays detailed option info.
#
#   Prerequisites:
#     # Ruby gems
#     gem install faraday -v "~>0.4.5"
#     gem install trollop
#     gem install yajl-ruby
#     # Python tools (must be in your PATH)
#     html2text.py: # https://github.com/aaronsw/html2text

require 'yajl'
require 'faraday'
require 'trollop'
require 'fileutils'

class ZenDesk2Tender
  class ResponseJSON < Faraday::Response::Middleware
    def parse(body)
      Yajl::Parser.parse(body)
    end
  end
 
  include FileUtils
  attr_reader :opts, :conn
  EXPORT_DIR = '.export-data'

  def initialize # {{{
    @author_email = {}
    @opts = Trollop::options do
      banner <<-EOM
    Usage:
      #{$0} -e <email> -p <password> -s <subdomain>

    Prerequisites:
      # Ruby gems
      gem install faraday -v "~>0.4.5"
      gem install trollop
      gem install yajl-ruby
      # Python tools (must be in your PATH)
      html2text.py: http://www.aaronsw.com/2002/html2text/

    Options:
      EOM
      opt :email,       "user email address", :type => String
      opt :password,    "user password",      :type => String
      opt :subdomain,   "subdomain",          :type => String
    end

    [:email, :password, :subdomain ].each do |option|
      Trollop::die option, "is required" if opts[option].nil?
    end
    if `which html2text.py`.empty?
      puts 'missing prerequisite: html2text.py is not in your PATH'
      exit
    end

    @conn = Faraday::Connection.new("http://#{opts[:subdomain]}.zendesk.com") do |b|
      b.adapter :net_http
      b.use ResponseJSON
    end
    conn.basic_auth(opts[:email], opts[:password])
  end # }}}

  def export_users # {{{
    response = conn.get('users.json')
    if response.success?
      dir_name = File.join(EXPORT_DIR,'users')
      mkdir_p dir_name
      response.body.each do |user|
        File.open(File.join(dir_name, "#{user['email'].gsub(/\W+/,'_')}.json"), "w") do |file|
          @author_email[user['id'].to_s] = user['email']
          file.puts(Yajl::Encoder.encode(
            :name => user['name'],
            :email => user['email'],
            :created_at => user['created_at'],
            :updated_at => user['updated_at'],
            :state => (user['roles'].to_i == 0 ? 'user' : 'support')
          ))
        end
      end
    else
      puts "failed to get users:"
      puts response.inspect
    end
  end # }}}

  def export_categories # {{{
    response = conn.get('forums.json')
    if response.success?
      dir_name = File.join(EXPORT_DIR,'categories')
      mkdir_p dir_name
      response.body.each do |forum|
        File.open(File.join(dir_name, "#{forum['id']}.json"), "w") do |file|
          file.puts(Yajl::Encoder.encode(
            :name => forum['name'],
            :summary => forum['description']
          ))
        end
        export_discussions(forum['id'])
      end
    else
      puts "failed to get categories:"
      puts response.inspect
    end
  end # }}}

  def export_tickets # {{{
    tickets = []
    page = 1
    loop do
      response = conn.get("search.json?query=type:ticket+status:open+status:pending+status:new&page=#{page}")
      if response.success?
        page += 1
        break unless response.body.size > 0
        # import tickets
        tickets += response.body
      elsif response.status == 503
        puts "got a 503 (API throttle), waiting 30 seconds..."
        sleep 30
      else
        puts "failed to get tickets:"
        puts response.inspect
      end
    end
    if tickets.size > 0
      # create category for tickets
      dir_name = File.join(EXPORT_DIR,'categories')
      mkdir_p "#{dir_name}"
      File.open(File.join(dir_name, "tickets.json"), "w") do |file|
        file.puts(Yajl::Encoder.encode(
          :name => 'Tickets',
          :summary => 'Imported from ZenDesk.'
        ))
      end
      # export tickets into new category
      dir_name = File.join(EXPORT_DIR,'categories', 'tickets')
      mkdir_p dir_name
      mkdir_p 'tmp'
      tickets.each do |ticket|
        File.open(File.join(dir_name, "#{ticket['nice_id']}.json"), "w") do |file|
          comments = ticket['comments'].map do |post|
            {
              :body => post['value'],
              :author_email => author_email(post['author_id']),
              :created_at => post['created_at'],
              :updated_at => post['updated_at'],
            }
          end
          file.puts(Yajl::Encoder.encode(
            :title        => ticket['subject'],
            :author_email => author_email(ticket['submitter_id']),
            :created_at   => ticket['created_at'],
            :updated_at   => ticket['updated_at'],
            :comments     => comments
          ))
        end
      end
    end
  end # }}}

  def export_discussions forum_id # {{{
    response = conn.get("forums/#{forum_id}/entries.json")
    if response.success?
      dir_name = File.join(EXPORT_DIR,'categories', forum_id.to_s)
      mkdir_p dir_name
      mkdir_p 'tmp'
      response.body.each do |entry|
        File.open(File.join(dir_name, "#{entry['id']}.json"), "w") do |file|
          posts = conn.get("entries/#{entry['id']}/posts.json")
          if posts.success?
            comments = posts.body['posts'].map do |post|
              dump_body post, post['body']
              {
                :body => load_body(entry),
                :author_email => author_email(post['user_id']),
                :created_at => post['created_at'],
                :updated_at => post['updated_at'],
              }
            end
          else
            puts "failed to get posts for entry #{entry['id']}:"
            puts posts.inspect
            comments = []
          end
          dump_body entry, entry['body']
          file.puts(Yajl::Encoder.encode(
            :title    => entry['title'],
            :comments => [{
              :body => load_body(entry),
              :author_email => author_email(entry['submitter_id']),
              :created_at => entry['created_at'],
              :updated_at => entry['updated_at'],
            }] + comments
          ))
          rm "tmp/#{entry['id']}_body.html"
        end
      end
    else
      puts "failed to get entries for forum #{forum_id}:"
      puts response.inspect
    end
  end # }}}

  def author_email user_id
    @author_email[user_id.to_s] ||= begin
       # the cache should be populated during export_users but we'll attempt
       # to fetch unrecognized ids just in case
       conn.get("users/#{user_id}.json").body['email'] rescue nil
    end
  end

  def dump_body entry, body
    File.open(File.join("tmp", "#{entry['id']}_body.html"), "w") do |file|
      file.write(body)
    end
  end

  def load_body entry
    `html2text.py /$PWD/tmp/#{entry['id']}_body.html`
  end

  def create_archive
    export_file = "export_#{opts[:subdomain]}.tgz"
    system "tar -zcf #{export_file} -C #{EXPORT_DIR} ."
    system "rm -rf #{EXPORT_DIR}"
    puts "created #{export_file}"
  end

  def self.run
    exporter = new
    exporter.export_users
    exporter.export_categories
    exporter.export_tickets
    exporter.create_archive
  end

end

# vi:foldmethod=marker