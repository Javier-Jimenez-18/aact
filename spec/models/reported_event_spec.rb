require 'rails_helper'
describe ReportedEvent do
  it "should not fail when expected data elements (such as sub_title) don't exist" do
    nct_id='NCT02317510'
    xml=Nokogiri::XML(File.read("spec/support/xml_data/#{nct_id}.xml"))
    study=Study.new({xml: xml, nct_id: nct_id}).create
    serious=study.reported_events.select{|x|x.event_type=='serious'}
  end

  it "should have expected values" do
    nct_id='NCT00023673'
    xml=Nokogiri::XML(File.read("spec/support/xml_data/#{nct_id}.xml"))
    study=Study.new({xml: xml, nct_id: nct_id}).create

    e1=study.reported_events.select{|x|x.ctgov_group_code=='E1'}
    e2=study.reported_events.select{|x|x.ctgov_group_code=='E2'}
    expect(e1.size).to eq(164)
    expect(e2.size).to eq(164)

    serious=study.reported_event_totals.select{|x|x.ctgov_group_code=='E2' and x.event_type=='serious'}
    expect(serious.size).to eq(1)
    e2_serious=serious.first
    expect(e2_serious.subjects_affected).to eq(36)
    expect(e2_serious.subjects_at_risk).to eq(53)
    expect(e2_serious.classification).to eq('Total, serious adverse events')
    
    e1_serious_cardiac_array=e1.select{|x|x.event_type=='serious' and x.organ_system=='Cardiac disorders'}
    expect(e1_serious_cardiac_array.size).to eq(3)
    e1_serious_cardiac=e1_serious_cardiac_array.select{|x|x.adverse_event_term=='Arrhythmia NOS'}.first
    expect(e1_serious_cardiac.subjects_affected).to eq(0)
    expect(e1_serious_cardiac.subjects_at_risk).to eq(8)

    events_with_assessment=study.reported_events.select{|x| x.assessment=='Systematic Assessment'}
    expect(events_with_assessment.size).to eq(24)
    bone_events=study.reported_events.select{|x| x.adverse_event_term=='Late RT Toxicity: Bone'}

    event=bone_events.select{|x| x.adverse_event_term=='Late RT Toxicity: Bone' and x.ctgov_group_code=='E2'}.first
    expect(event.subjects_affected).to eq(1)
    expect(event.subjects_at_risk).to eq(53)
    expect(event.vocab).to eq('RTOG/EORTC Late Tox.')
  end

  it "should have expected values" do
    nct_id='NCT02028676'
    xml=Nokogiri::XML(File.read("spec/support/xml_data/#{nct_id}.xml"))
    study=Study.new({xml: xml, nct_id: nct_id}).create
    other_events=study.reported_events.select{|x|x.event_type=='other'}
    expect(other_events.size).to eq(27)
    expect(other_events.select{|x|x.frequency_threshold==5}.size).to eq(27)
    expect(other_events.select{|x|x.default_vocab=='Trial-specific'}.size).to eq(27)
    expect(other_events.select{|x|x.default_assessment=='Systematic Assessment'}.size).to eq(27)

  end
end
