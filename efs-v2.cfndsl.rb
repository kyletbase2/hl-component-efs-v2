CloudFormation do

  tags, lifecycles = Array.new(2){[]}
  tags.push(
    { Key: 'Environment', Value: Ref(:EnvironmentName) },
    { Key: 'EnvironmentType', Value: Ref(:EnvironmentType) },
    { Key: 'Name', Value: FnSub("${EnvironmentName}-#{external_parameters[:component_name]}")}
  )

  extra_tags = external_parameters.fetch(:extra_tags, {})
  extra_tags.each { |key,value| tags << { Key: key, Value: value } }

  ip_blocks = external_parameters.fetch(:ip_blocks, {})
  security_group_rules = external_parameters.fetch(:security_group_rules, [])

  EC2_SecurityGroup('SecurityGroupEFS') do
    GroupDescription FnSub("${EnvironmentName} #{external_parameters[:component_name]}")
    VpcId Ref('VPCId')
    if security_group_rules.any?
      # https://github.com/theonestack/hl-component-lib-ec2/blob/master/ext/cfndsl/security_group.rb
      SecurityGroupIngress generate_security_group_rules(security_group_rules,ip_blocks) # helper function comes from lib-ec2 component
    end
    Tags tags
  end

  encrypt = external_parameters.fetch(:encrypt, false)
  kms = external_parameters.fetch(:kms, false)
  # Ensure value provided in config is a boolean, that is what cloudformation expects
  {kms: kms, encrypt: encrypt}.each { |key, value| raise ArgumentError, "#{key} config value must be a boolean" unless [true, false].include?(value) }

  lifecycle_policies = external_parameters.fetch(:lifecycle_policies, [])
  lifecycle_policies.each { |rule| lifecycles.push({TransitionToIA: rule})}

  if lifecycles.any?
    allowed = %w(
      AFTER_14_DAYS
      AFTER_30_DAYS
      AFTER_60_DAYS
      AFTER_7_DAYS
      AFTER_90_DAYS
    )
    lifecycles.each {|cycle| raise ArgumentError, "Lifecycle value: #{cycle[:TransitionToIA]} must match one of #{allowed}" unless allowed.include?(cycle[:TransitionToIA]) }
  end

  performance_mode = external_parameters.fetch(:performance_mode, nil)
  if !performance_mode.nil?
    # Ensure value provided in config matches allowed values expected by cloudformation
    raise ArgumentError, "performance_mode value can only be set to generalPurpose or maxIO" unless %w(generalPurpose maxIO).include? performance_mode
  end

  throughput_mode = external_parameters.fetch(:throughput_mode, nil)
  provisioned_throughput = external_parameters.fetch(:provisioned_throughput, nil)
  if !throughput_mode.nil?
    # Ensure value provided in config matches allowed values expected by cloudformation
    raise ArgumentError, "throughput_mode value can only be set to bursting or provisioned" unless %w(bursting provisioned).include? throughput_mode
    if (throughput_mode == 'provisioned' && provisioned_throughput.nil?)
      raise ArgumentError, "When setting throughput_mode to provisioned, provisioned_throughput value must be defined"
    end
  end

  if !provisioned_throughput.nil?
    # Provisioned throughput is expected as a double
    raise ArgumentError, "provisioned_throughput value must be a double, e.g 10.1" unless provisioned_throughput.class.eql?(Float)
  end


  EFS_FileSystem('FileSystem') do
    Encrypted encrypt if encrypt
    KmsKeyId Ref('KmsKeyId') if (encrypt && kms)
    PerformanceMode performance_mode unless performance_mode.nil?
    ProvisionedThroughputInMibps provisioned_throughput unless provisioned_throughput.nil?
    ThroughputMode throughput_mode unless throughput_mode.nil?
    LifecyclePolicies lifecycles if lifecycles.any?
    FileSystemTags tags
  end

  external_parameters[:max_availability_zones].times do |az|

    matches = ((az+1)..external_parameters[:max_availability_zones]).to_a
    Condition("CreateEFSMount#{az}",
      matches.length == 1 ? FnEquals(Ref(:AvailabilityZones), external_parameters[:max_availability_zones]) : FnOr(matches.map { |i| FnEquals(Ref(:AvailabilityZones), i) })
    )

    EFS_MountTarget("MountTarget#{az}") do
      Condition("CreateEFSMount#{az}")
      FileSystemId Ref('FileSystem')
      SecurityGroups [ Ref("SecurityGroupEFS") ]
      SubnetId FnSelect(az, Ref('SubnetIds'))
    end

  end

  Output('FileSystem', Ref('FileSystem'))

  Output('EFSSecurityGroup', Ref('SecurityGroupEFS'))

end