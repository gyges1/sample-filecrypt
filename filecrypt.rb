require 'sinatra'
require 'net/http'
require 'net/https'
require 'json'
require 'base64'
require 'openssl'
require 'aws/s3'

set :s3_bucket, ENV['AWS_BUCKET']
set :s3_key, ENV['AWS_KEY']
set :s3_secret, ENV['AWS_SECRET']
set :salesforce_instance, ENV['SFDC_INSTANCE']
set :aes_key, Base64.decode64(ENV['AES_KEY'])

def decrypt(encrypted_data)
  aes = OpenSSL::Cipher::Cipher.new('AES-256-CBC')
  aes.decrypt
  aes.key = settings.aes_key
  aes.iv = encrypted_data.slice!(0,16)
  data = aes.update(encrypted_data)
  data << aes.final
end
  
def encrypt(data)
  aes = OpenSSL::Cipher::Cipher.new('AES-256-CBC')
  aes.encrypt
  aes.key = settings.aes_key
  aes.iv = initialization_vector = aes.random_iv
  cipher_text = aes.update(data)
  cipher_text << aes.final
  return initialization_vector + cipher_text
end

get '/' do
  ""
end

get '/download/:user/:filename' do
  #add in code to validate user via sid - same as upload
  AWS::S3::Base.establish_connection!(:access_key_id => settings.s3_key, :secret_access_key => settings.s3_secret)
  s3_path = params[:user] + '/' + params[:filename]
  file = AWS::S3::S3Object.find(s3_path, settings.s3_bucket)
  status 200
  headers \
    "Content-type"   => file.content_type
  body decrypt(file.value)
end


post '/upload' do
  sid = params[:session]
  user = params[:user]
  org = params[:org]
  header = 'OAuth ' + params[:session]
  
  sfdc = Net::HTTP.new(settings.salesforce_instance, 443)
  sfdc.use_ssl = true
  headers = {'Authorization'=> header}
  id_path = '/id/' + org + '/' + user + '?format=json&version=latest'
  resp, data = sfdc.get(id_path, headers)
  
  if resp = Net::HTTPSuccess
    user_info = JSON.parse(data)   
  
    if user_info['asserted_user'] &&  params[:file] && ( params[:file].size > 0 )
      tmpfile = params[:file][:tempfile].path
      filename = params[:file][:filename]
      s3_path = user + '/' + filename 
  
      encrypted_file = encrypt(File.open(tmpfile).read)
  
      AWS::S3::Base.establish_connection!(:access_key_id => settings.s3_key, :secret_access_key => settings.s3_secret)
      AWS::S3::S3Object.store(s3_path, encrypted_file, settings.s3_bucket, :access => :private)    
  
      headers = {'Authorization'=> header, 'Content-Type'=> 'application/json' }
      path = '/services/data/v21.0/sobjects/cmort__EncryptedFile__c'
      s3_url = 'https://filecrypt.heroku.com/download/' + s3_path
      data = {"Name" => filename, "cmort__FileURL__c" => s3_url }
      resp, data = sfdc.post(path, data.to_json, headers)   
      puts resp
      puts data
    else
      return 'invalid user'
    end
  else 
    return 'error validating user'
  end
  redirect to('https://' + settings.salesforce_instance + '/apex/MyFiles')
end

