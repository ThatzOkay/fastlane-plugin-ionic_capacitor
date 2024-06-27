describe Fastlane::Actions::IonicCapacitorAction do
  describe '#run' do
    it 'prints a message' do
      expect(Fastlane::UI).to receive(:message).with("The ionic_capacitor plugin is working!")

      Fastlane::Actions::IonicCapacitorAction.run(nil)
    end
  end
end
