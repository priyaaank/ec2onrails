#!/usr/bin/ruby

#    This file is part of EC2 on Rails.
#    http://rubyforge.org/projects/ec2onrails/
#
#    Copyright 2007 Paul Dowman, http://pauldowman.com/
#
#    EC2 on Rails is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    EC2 on Rails is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.

exit unless File.stat("/etc/init.d/mysql").executable?
exit unless File.exists?("/mnt/app/current")

require "rubygems"
require "optiflag"
require "fileutils"
require "#{File.dirname(__FILE__)}/../lib/mysql_helper"
require "#{File.dirname(__FILE__)}/../lib/s3_helper"
require "#{File.dirname(__FILE__)}/../lib/utils"

module CommandLineArgs extend OptiFlagSet
  optional_flag "bucket"
  optional_flag "dir"
  optional_switch_flag "incremental"
  and_process!
end

# include the hostname in the bucket name so test instances don't accidentally clobber real backups
bucket_suffix = ARGV.flags.bucket || Ec2onrails::Utils.hostname
dir = ARGV.flags.dir || "database"
@s3 = Ec2onrails::S3Helper.new(bucket_suffix, dir)
@mysql = Ec2onrails::MysqlHelper.new
@temp_dir = "/tmp/ec2onrails-backup-#{bucket_suffix}-#{dir}"
if File.exists?(@temp_dir)
  puts "Temp dir exists (#{@temp_dir}), aborting. Is another backup process running?"
  exit
end
  
begin
  FileUtils.mkdir_p @temp_dir
  if ARGV.flags.incremental
    # Incremental backup
    @mysql.execute_sql "flush logs"
    logs = Dir.glob("/mnt/log/mysql/mysql-bin.[0-9]*").sort
    logs_to_archive = logs[0..-2] # all logs except the last
    logs_to_archive.each {|log| @s3.store_file log}
    @mysql.execute_sql "purge master logs to '#{File.basename(logs[-1])}'"
  else
    # Full backup. Purge binary logs and do a mysqldump
    file = "#{@temp_dir}/dump.sql.gz"
    @mysql.execute_sql "reset master"
    @mysql.dump file
    @mysql.execute_sql "purge master logs to 'mysql-bin.000002'"
    @s3.store_file file
    @s3.delete_files("mysql-bin")
  end
ensure
  FileUtils.rm_rf(@temp_dir)
end
