require File.expand_path '../../test_helper.rb', __FILE__

class TokenIntrospectionSequenceTest < MiniTest::Unit::TestCase

  REQUEST_HEADERS = { 'Accept' => 'application/json', 'Content-type' => 'application/x-www-form-urlencoded' }

  def setup

    introspect_token = JSON::JWT.new({iss: 'foo'})
    resource_id = SecureRandom.uuid
    resource_secret = SecureRandom.hex(32)

    @instance = TestingInstance.new(url: 'http://www.example.com',
                                   client_name: 'Crucible Smart App',
                                   base_url: 'http://localhost:4567',
                                   scopes: 'launch openid patient/*.* profile',
                                   oauth_introspection_endpoint: 'https://oauth_reg.example.com/introspect',
                                   introspect_token: introspect_token,
                                   resource_id: resource_id,
                                   resource_secret: resource_secret,
                                   token_retrieved_at: DateTime.now
                                   )
    @instance.save! # this is for convenience.  we could rewrite to ensure nothing gets saved within tests.
    client = FHIR::Client.new(@instance.url)
    client.use_dstu2
    client.default_json
    @sequence = TokenIntrospectionSequence.new(@instance, client, true)
  end

  def test_all_pass
    WebMock.reset!
    params = {
      'token' => @instance.introspect_token,
      'client_id' => @instance.resource_id,
      'client_secret' => @instance.resource_secret
    }
    response = {
      "active" => true,
      "scope" => @instance.scopes,
      "exp" => 2.hours.from_now.to_i
    }

    stub_register = stub_request(:post, @instance.oauth_introspection_endpoint).
      with(headers: REQUEST_HEADERS, body: params).
      to_return(status: 200, body: response.to_json)

    sequence_result = @sequence.start

    assert_requested(stub_register)

    failures = sequence_result.test_results.select{|r| r.result != 'pass' && r.result != 'skip'}

    assert failures.length == 0, "All tests should pass.  First error: #{!failures.empty? && failures.first.message}"
    assert sequence_result.result == 'pass', 'Sequence should pass.'
    assert sequence_result.test_results.all?{|r| r.test_warnings.empty? }, 'There should not be any warnings.'
  end

  def test_no_introspection_endpoint
    WebMock.reset!
    params = {
      'token' => @instance.introspect_token,
      'client_id' => @instance.resource_id,
      'client_secret' => @instance.resource_secret
    }

    stub_register = stub_request(:post, @instance.oauth_introspection_endpoint).
      with(headers: REQUEST_HEADERS, body: params).
      to_return(status: 404)

    sequence_result = @sequence.start

    assert_requested(stub_register)

    assert sequence_result.result == 'fail', 'Sequence should fail.'
    assert sequence_result.test_results.all?{|r| r.result == 'fail' || r.result == 'skip'}, 'All tests should fail.'
  end

  def test_inactive
    WebMock.reset!
    params = {
      'token' => @instance.introspect_token,
      'client_id' => @instance.resource_id,
      'client_secret' => @instance.resource_secret
    }
    response = {
      "active" => false,
      "scope" => @instance.scopes,
      "exp" => 2.hours.from_now.to_i
    }

    stub_register = stub_request(:post, @instance.oauth_introspection_endpoint).
      with(headers: REQUEST_HEADERS, body: params).
      to_return(status: 200, body: response.to_json)

    sequence_result = @sequence.start

    assert_requested(stub_register)

    failures = sequence_result.test_results.select{|r| r.result != 'pass' && r.result != 'skip'}

    # 1 test depends on active being true
    assert failures.length == 1, 'One test should fail.'
    assert sequence_result.result == 'fail', 'Sequence should fail.'
  end

  def test_insufficient_scopes
    WebMock.reset!
    params = {
      'token' => @instance.introspect_token,
      'client_id' => @instance.resource_id,
      'client_secret' => @instance.resource_secret
    }
    response = {
      "active" => true,
      "scope" => @instance.scopes.split(' ')[0...-1].join(' '), # remove last scope
      "exp" => 2.hours.from_now.to_i
    }

    stub_register = stub_request(:post, @instance.oauth_introspection_endpoint).
      with(headers: REQUEST_HEADERS, body: params).
      to_return(status: 200, body: response.to_json)

    sequence_result = @sequence.start

    assert_requested(stub_register)

    failures = sequence_result.test_results.select{|r| r.result != 'pass' && r.result != 'skip'}
    warnings = sequence_result.test_results.select{|r| !r.test_warnings.empty?}

    # 1 optional test depends on correct scopes
    assert failures.length == 1, "One test should fail."
    assert sequence_result.result == 'pass', 'Sequence should pass.'
  end

  def test_additional_scopes
    WebMock.reset!
    params = {
      'token' => @instance.introspect_token,
      'client_id' => @instance.resource_id,
      'client_secret' => @instance.resource_secret
    }
    response = {
      "active" => true,
      "scope" => @instance.scopes + ' extra', # add extra scope
      "exp" => 2.hours.from_now.to_i
    }

    stub_register = stub_request(:post, @instance.oauth_introspection_endpoint).
      with(headers: REQUEST_HEADERS, body: params).
      to_return(status: 200, body: response.to_json)

    sequence_result = @sequence.start

    assert_requested(stub_register)

    failures = sequence_result.test_results.select{|r| r.result != 'pass' && r.result != 'skip'}
    warnings = sequence_result.test_results.select{|r| !r.test_warnings.empty?}

    # 1 optional test depends on correct scopes
    assert failures.length == 1, "One test should fail."
    assert sequence_result.result == 'pass', 'Sequence should pass.'
  end

  def test_expiration
    WebMock.reset!
    params = {
      'token' => @instance.introspect_token,
      'client_id' => @instance.resource_id,
      'client_secret' => @instance.resource_secret
    }
    response = {
      "active" => false,
      "scope" => @instance.scopes,
      "exp" => 30.minutes.from_now.to_i # should be at least 60 minutes
    }

    stub_register = stub_request(:post, @instance.oauth_introspection_endpoint).
      with(headers: REQUEST_HEADERS, body: params).
      to_return(status: 200, body: response.to_json)

    sequence_result = @sequence.start

    assert_requested(stub_register)

    failures = sequence_result.test_results.select{|r| r.result != 'pass' && r.result != 'skip'}

    # 1 test depends on expiration being at least 60 minutes
    assert failures.length == 1, 'One test should fail.'
    assert sequence_result.result == 'fail', 'Sequence should fail.'
  end

end
